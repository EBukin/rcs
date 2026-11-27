# Rasters: staging a `terra::SpatRaster` as one Cloud Optimized GeoTIFF with
# its catalog entry and file row, and opening a stored raster through GDAL.
#
# Rules (see plan 0001, "Rasters", and plan 0006, part A):
#   * One file per dataset, `<dataset>/part-<version>.tif`; no partitions.
#   * Nothing of the package is embedded in the TIFF; the manifest, built by
#     the caller from `entry` and `files`, describes the file. Layer names
#     travel as GDAL band descriptions, which terra and GDAL write and read
#     themselves.
#   * Every layer of a GeoTIFF has one data type, one of `raster_types`
#     (`raster_datatype()`): the type asked for; else the type of the source
#     file(s) of a file-backed raster without scale or offset, found with no
#     pass over the cells; else, for
#     whole numbers, the smallest integer type that holds the values and
#     leaves its default NoData flag free; else `FLT8S`. The type is recorded
#     per layer in `columns$type` as terra reports it for the written file.
#   * One NoData value for all layers (`raster_nodata()`): the one asked for;
#     else a flag set in the session; else the tag of the source file; else,
#     for an integer type, the type's default flag (always when the type was
#     chosen from the values, only when cells are missing otherwise). It is
#     always passed to GDAL explicitly and recorded as `r_type$nodata`. "No
#     NoData value" is written as `NAflag = NaN` by terra and as
#     `-a_nodata none` by GDAL; missing cells of a float layer are `NaN`.
#   * Creation options (`raster_gdal_options()`): DEFLATE, a predictor, 512
#     blocks, `BIGTIFF=IF_SAFER`, overviews built anew (never copied from the
#     source), NEAREST for integers and AVERAGE for floats; `gdal =` replaces
#     them by key; they are sorted by key, so that the order given does not
#     change the file.
#   * Categorical layers are stored as codes. Their legend (codes, labels of
#     the active category, name of the label column) goes to the layer's
#     `r_type` (`values`, `levels`, `levels_name`) and `raster_open()` sets it
#     again from there. The file is written from a copy without levels, so no
#     side file (`.aux.xml`) is ever written and the same cells with and
#     without a legend give the same file.
#   * The time and units of layers (`terra::time()`, `terra::units()`) are
#     not stored (plan 0006, AM10): the file is written from a copy without
#     them, so they change neither its bytes nor the version, and terra
#     writes no side file for them (`.aux.json`). Side files are removed
#     after the write in any case. Only what GDAL copies of the metadata of a
#     source file on the translate path stays in the TIFF.
#   * Two ways to write (`raster_write()`): an unchanged view of one file
#     (same cells, names, CRS and NoData value; no scale or offset) is copied
#     by GDAL (`gdal_translate`), which needs no intermediate file; everything
#     else is written by terra. Either way the file reads back as `x` does:
#     values, layer names, CRS. Their bytes may differ.
#   * Every temp file lies below the staging folder: terra's temp folder is a
#     subfolder of the staging temp folder while terra writes. Staging warns
#     (class `rcs_warning_staging_space`) when the staging drive looks too
#     small for a file-backed raster.
#   * Writing is deterministic: two stagings of the same raster give the same
#     MD5 and the same version.

check_terra <- function(call = caller_env()) {
  rlang::check_installed("terra", reason = "to store rasters.", call = call)
}

raster_abort <- function(message, ..., call = caller_env(), .envir = parent.frame()) {
  cli::cli_abort(message, ..., class = "rcs_error_raster", call = call, .envir = .envir)
}

# PROJJSON of a raster's CRS, or NA when it has none.
raster_crs_json <- function(x) {
  wkt <- terra::crs(x)
  if (!nzchar(wkt)) {
    return(NA_character_)
  }
  crs <- tryCatch(sf::st_crs(wkt), error = function(e) sf::NA_crs_)
  if (is.na(crs)) NA_character_ else crs$ProjJson
}

# Extent of a raster as a named double `c(xmin, ymin, xmax, ymax)`.
raster_bbox <- function(x) {
  e <- as.vector(terra::ext(x))
  c(xmin = e[["xmin"]], ymin = e[["ymin"]], xmax = e[["xmax"]], ymax = e[["ymax"]])
}

check_raster_descriptions <- function(descriptions, layers, call = caller_env()) {
  if (is.null(descriptions)) {
    return(invisible())
  }
  if (!is.character(descriptions) || !rlang::is_named(descriptions)) {
    cli::cli_abort(
      "{.arg columns} must be a named character vector of descriptions.",
      class = "rcs_error_argument", call = call
    )
  }
  unknown <- setdiff(names(descriptions), layers)
  if (length(unknown) > 0) {
    cli::cli_abort(
      "{.arg columns} describes layer{?s} the raster lacks: {.field {unknown}}.",
      class = "rcs_error_argument", call = call
    )
  }
  invisible()
}

# Data types, NoData and creation options --------------------------------------

# The data types a raster can be stored with (plan 0006, D-A1), the range and
# the default NoData flag of the integer ones, and GDAL's names for them.
raster_types <- c("INT1U", "INT2U", "INT2S", "INT4U", "INT4S", "FLT4S", "FLT8S")

raster_integer_types <- list(
  INT1U = list(min = 0, max = 255, flag = 255),
  INT2U = list(min = 0, max = 65535, flag = 65535),
  INT2S = list(min = -32768, max = 32767, flag = -32768),
  INT4U = list(min = 0, max = 4294967295, flag = 4294967295),
  INT4S = list(min = -2147483648, max = 2147483647, flag = -2147483648)
)

raster_gdal_types <- c(
  INT1U = "Byte", INT2U = "UInt16", INT2S = "Int16", INT4U = "UInt32",
  INT4S = "Int32", FLT4S = "Float32", FLT8S = "Float64"
)

# Checks of the arguments `datatype`, `nodata` and `gdal`, as far as they can
# be checked without the raster. Aborts with class `rcs_error_argument`.
check_raster_arguments <- function(datatype, nodata, gdal, call = caller_env()) {
  if (!is.null(datatype) && !(rlang::is_string(datatype) && datatype %in% raster_types)) {
    cli::cli_abort(
      c(
        "{.arg datatype} must be {.code NULL} or one of {.or {.val {raster_types}}}.",
        x = if (rlang::is_string(datatype)) {
          "Not {.val {datatype}}."
        } else {
          "Not {.obj_type_friendly {datatype}}."
        }
      ),
      class = "rcs_error_argument", call = call
    )
  }
  if (!is.null(nodata) && !(is.numeric(nodata) && length(nodata) == 1 && is.finite(nodata))) {
    cli::cli_abort(
      "{.arg nodata} must be {.code NULL} or one finite number, not {.obj_type_friendly {nodata}}.",
      class = "rcs_error_argument", call = call
    )
  }
  check_raster_gdal(gdal, call = call)
  invisible()
}

check_raster_gdal <- function(gdal, call = caller_env()) {
  if (is.null(gdal)) {
    return(invisible())
  }
  if (!is.character(gdal) || anyNA(gdal) || !all(grepl("^[A-Za-z0-9_]+=.+$", gdal))) {
    cli::cli_abort(
      c(
        "{.arg gdal} must be {.code NULL} or a character vector of {.code KEY=VALUE} creation options.",
        i = "For example {.code gdal = c(\"COMPRESS=ZSTD\", \"BLOCKSIZE=256\")}."
      ),
      class = "rcs_error_argument", call = call
    )
  }
  keys <- toupper(sub("=.*$", "", gdal))
  if (anyDuplicated(keys) > 0) {
    cli::cli_abort(
      "{.arg gdal} names {.code {unique(keys[duplicated(keys)])}} more than once.",
      class = "rcs_error_argument", call = call
    )
  }
  invisible()
}

# `TRUE` where a layer holds whole numbers: integer cells, or the codes of a
# categorical layer (`terra::is.int()` is `FALSE` for those).
raster_is_whole <- function(x) {
  terra::is.int(x) | terra::is.factor(x)
}

# `TRUE` when every layer of `x` is read from a file and none is in memory
# (plan 0006, AM2). `terra::datatype()` alone does not tell: it keeps the
# file's type after the cells were read into memory or changed.
raster_is_file_backed <- function(x) {
  !any(terra::inMemory(x)) && all(nzchar(terra::sources(x, bands = TRUE)$source))
}

# The smallest and largest value of all layers, missing cells ignored;
# `numeric()` when every cell is missing. A pass over the cells.
raster_value_range <- function(x) {
  limits <- as.vector(terra::minmax(x, compute = TRUE))
  limits <- limits[is.finite(limits)]
  if (length(limits) == 0) numeric() else range(limits)
}

# The data type of the file (plan 0006, D-A2, D-A4, AM2); first rule that
# applies:
#   1. `datatype`, when given. An integer type needs whole numbers inside its
#      range, else the call aborts with class `rcs_error_raster`.
#   2. The type of the source, when `x` is file-backed, all its layers have
#      one type and it is one of `raster_types`. No pass over the cells. Not
#      for a raster with a scale or offset (AM9): the type of its source is
#      the type of the stored numbers, not of the values `x` reads.
#   3. Whole numbers: the first integer type whose range holds the values and
#      the NoData value known so far (`nodata`, a flag or a tag), or, with
#      none known, leaves the type's default flag free. `FLT8S` when none does.
#   4. `FLT8S`.
# Returns one string. Two attributes carry what `raster_nodata()` needs:
# `auto` (`TRUE` under rule 3) and `range` (the value range, when computed).
raster_datatype <- function(x, datatype, nodata) {
  call <- rlang::caller_env()
  whole <- all(raster_is_whole(x))
  if (!is.null(datatype)) {
    limits <- raster_integer_types[[datatype]]
    if (is.null(limits)) {
      return(datatype)
    }
    if (!whole) {
      raster_abort(
        c(
          "The raster cannot be stored as {.val {datatype}}: its values are not whole numbers.",
          x = "Layer{?s} with other values: {.field {names(x)[!raster_is_whole(x)]}}.",
          i = "Round them, e.g. with {.code terra::as.int()}, or use a float type."
        ),
        call = call
      )
    }
    found <- raster_value_range(x)
    if (length(found) == 2 && (found[[1]] < limits$min || found[[2]] > limits$max)) {
      raster_abort(
        c(
          "The values do not fit the data type {.val {datatype}}.",
          x = "Values found: {format_number(found[[1]])} to {format_number(found[[2]])}.",
          i = "{.val {datatype}} holds {format_number(limits$min)} to {format_number(limits$max)}."
        ),
        call = call
      )
    }
    return(structure(datatype, range = found))
  }
  if (raster_is_file_backed(x) && !raster_is_scaled(x)) {
    types <- unique(terra::datatype(x))
    if (length(types) == 1 && types %in% raster_types) {
      return(types)
    }
  }
  if (!whole) {
    return("FLT8S")
  }
  found <- raster_value_range(x)
  known <- nodata %||% raster_marked_nodata(x, call = call)
  for (type in names(raster_integer_types)) {
    limits <- raster_integer_types[[type]]
    holds <- length(found) == 0 || (found[[1]] >= limits$min && found[[2]] <= limits$max)
    free <- if (is.null(known)) {
      length(found) == 0 || limits$flag < found[[1]] || limits$flag > found[[2]]
    } else {
      known != round(known) || (known >= limits$min && known <= limits$max)
    }
    if (holds && free) {
      return(structure(type, auto = TRUE, range = found))
    }
  }
  "FLT8S"
}

# The NoData value of the file, or `NULL` for none (plan 0006, D-A3, AM5);
# `datatype` is the result of `raster_datatype()`. First rule that applies:
#   1. `nodata`, when given; it must be representable in the type, else the
#      call aborts with class `rcs_error_argument`.
#   2. and 3. The flag set on `x` in the session, else the NoData tag of its
#      source file (`raster_missing_marker()`). Layers that differ abort
#      with class `rcs_error_raster`.
#   4. An integer type chosen from the values: the type's default flag.
#   5. Any other integer type: the default flag when cells are missing (the
#      call aborts when a value equals it), else none.
#   6. A float type: none; missing cells are `NaN` in the file.
raster_nodata <- function(x, datatype, nodata) {
  call <- rlang::caller_env()
  type <- as.vector(datatype)
  if (!is.null(nodata)) {
    if (!raster_nodata_fits(nodata, type)) {
      cli::cli_abort(
        c(
          "{.arg nodata} cannot be stored in the data type {.val {type}}.",
          x = "Given: {format_number(nodata)}.",
          i = raster_type_hint(type)
        ),
        class = "rcs_error_argument", call = call
      )
    }
    return(as.double(nodata))
  }
  marked <- raster_marked_nodata(x, call = call)
  if (!is.null(marked)) {
    if (!raster_nodata_fits(marked, type)) {
      raster_abort(
        c(
          "The NoData value of the raster cannot be stored in the data type {.val {type}}.",
          x = "NoData value: {format_number(marked)}.",
          i = raster_type_hint(type),
          i = "Give another one with {.arg nodata}."
        ),
        call = call
      )
    }
    return(marked)
  }
  limits <- raster_integer_types[[type]]
  if (is.null(limits)) {
    return(NULL)
  }
  if (isTRUE(attr(datatype, "auto"))) {
    return(limits$flag)
  }
  if (!any(terra::global(x, "isNA")[[1]] > 0)) {
    return(NULL)
  }
  found <- attr(datatype, "range") %||% raster_value_range(x)
  if (limits$flag %in% found) {
    raster_abort(
      c(
        "The raster has missing cells and no free value to mark them in {.val {type}}.",
        x = "A cell holds {format_number(limits$flag)}, the NoData value of {.val {type}}.",
        i = "Give a free value with {.arg nodata}, or a larger {.arg datatype}."
      ),
      call = call
    )
  }
  limits$flag
}

raster_nodata_fits <- function(value, type) {
  limits <- raster_integer_types[[type]]
  if (!is.null(limits)) {
    return(value == round(value) && value >= limits$min && value <= limits$max)
  }
  is.finite(value) && (type != "FLT4S" || abs(value) <= 3.4028234663852886e38)
}

raster_type_hint <- function(type) {
  limits <- raster_integer_types[[type]]
  if (is.null(limits)) {
    return(paste0(type, " holds finite numbers of single precision."))
  }
  paste0(
    type, " holds whole numbers from ", format_number(limits$min), " to ",
    format_number(limits$max), "."
  )
}

# A number as text for messages, without exponent where it can be avoided.
format_number <- function(x) {
  sprintf("%.15g", x)
}

# The flag set in the session on each layer of `x` (`terra::NAflag()` has one
# value per source): a double, one per layer; `NA` when none is set.
raster_session_flag <- function(x) {
  src <- terra::sources(x, bands = TRUE)
  flags <- terra::NAflag(x)[match(src$sid, unique(src$sid))]
  if (length(flags) != nrow(src)) {
    return(rep(NA_real_, nrow(src)))
  }
  flags[!is.finite(flags)] <- NA_real_
  flags
}

# The NoData value each layer of `x` brings along: the flag set in the
# session, else the NoData tag of the layer's source band; `NA` when neither
# exists. Both must be in the units `x` reads, because the file is written
# with them:
#   * terra compares a session flag with the values `x` reads, also on a
#     layer with a scale or offset, so it is always usable;
#   * the source tag is compared with the stored numbers. For a layer whose
#     `terra::scoff()` is not 1 and 0 it is another number than the values
#     `x` reads, and it is ignored (plan 0006, AM10): written as it is, it
#     would turn valid cells that read as that number into missing ones. A
#     scaled source opened with `raw = TRUE` reads the stored numbers, has a
#     `scoff()` of 1 and 0, and keeps its tag.
raster_missing_marker <- function(x) {
  flags <- raster_session_flag(x)
  tags <- raster_source_nodata(x)
  scoff <- terra::scoff(x)
  scaled <- scoff[, 1] != 1 | scoff[, 2] != 0
  tags[!is.na(scaled) & scaled] <- NA_real_
  ifelse(is.na(flags), tags, flags)
}

# The one value that marks missing cells in every layer of `x`, or `NULL`
# when no layer has one. Aborts with class `rcs_error_raster` when the layers
# differ, a layer without one included: one file has one NoData value.
raster_marked_nodata <- function(x, call = caller_env()) {
  marker <- raster_missing_marker(x)
  if (all(is.na(marker))) {
    return(NULL)
  }
  if (anyNA(marker) || length(unique(marker)) > 1) {
    shown <- paste0(names(x), " ", ifelse(is.na(marker), "none", format_number(marker)))
    raster_abort(
      c(
        "The layers have different NoData values, and one file holds one.",
        x = "Found: {shown}.",
        i = "Give the value to write with {.arg nodata}."
      ),
      call = call
    )
  }
  marker[[1]]
}

# What GDAL reports for the source band of each layer of `x`, read from its
# description of the file (`gdalinfo -json`): a data frame with one row per
# layer and the columns
#   * `nodata`: the NoData tag; `NA` when the band has none or it is not
#     finite (`nan`);
#   * `description`: the band description, which terra reads as the layer
#     name; `""` when the band has none (terra then names the layer after
#     the file);
#   * `scale`, `offset`: 1 and 0 when the band has none. They are the file's
#     own, also when `x` was opened with `raw = TRUE`.
# A layer in memory, or of a file GDAL cannot describe, has `NA`, `""`, 1, 0.
raster_source_bands <- function(x) {
  src <- terra::sources(x, bands = TRUE)
  out <- data.frame(
    nodata = rep(NA_real_, nrow(src)), description = "", scale = 1, offset = 0,
    stringsAsFactors = FALSE
  )
  number <- function(value, default) {
    value <- if (is.null(value)) default else suppressWarnings(as.numeric(value))
    if (is.finite(value)) value else default
  }
  for (file in unique(src$source[nzchar(src$source)])) {
    info <- tryCatch(
      jsonlite::fromJSON(
        paste(terra::describe(file, options = "json"), collapse = "\n"),
        simplifyVector = FALSE
      ),
      error = function(e) NULL
    )
    for (row in which(src$source == file)) {
      band <- src$bands[[row]]
      if (band > length(info$bands)) {
        next
      }
      band <- info$bands[[band]]
      out$nodata[[row]] <- number(band[["noDataValue"]], NA_real_)
      out$description[[row]] <- as.character(band[["description"]] %||% "")
      out$scale[[row]] <- number(band[["scale"]], 1)
      out$offset[[row]] <- number(band[["offset"]], 0)
    }
  }
  out
}

# The finite NoData tag of the source band of each layer of `x`: a double,
# one per layer; `NA` when the band has none, it is not finite (`nan`), or
# the layer is in memory. terra does not report it (`terra::NAflag()` gives
# only a flag set in the session), so it is read from GDAL's description.
raster_source_nodata <- function(x) {
  raster_source_bands(x)$nodata
}

# `TRUE` when a layer of `x` has a scale or an offset (plan 0006, AM9): set
# in the session (`terra::scoff()`), or held by its source band. The latter
# counts also when `x` was opened with `raw = TRUE` and reads the stored
# numbers: a copy of the file would carry the scale along.
raster_is_scaled <- function(x) {
  session <- terra::scoff(x)
  bands <- raster_source_bands(x)
  any(session[, 1] != 1 | session[, 2] != 0, na.rm = TRUE) ||
    any(bands$scale != 1 | bands$offset != 0)
}

# The creation options of the COG, as `KEY=VALUE` strings (plan 0006, D-A5,
# AM1, AM10). A key of `gdal` replaces the default of that key, other keys
# are added; keys are compared in upper case and the result is sorted by key,
# so that the order given does not change the file. `OVERVIEWS=IGNORE_EXISTING`
# makes GDAL build the overviews with the resampling asked for, where it
# would otherwise copy those of a source that has some; a source without
# overviews gives the same file with and without it.
raster_gdal_options <- function(datatype, gdal) {
  check_raster_gdal(gdal, call = rlang::caller_env())
  whole <- datatype %in% names(raster_integer_types)
  options <- c(
    BIGTIFF = "IF_SAFER",
    BLOCKSIZE = "512",
    COMPRESS = "DEFLATE",
    OVERVIEWS = "IGNORE_EXISTING",
    OVERVIEW_RESAMPLING = if (whole) "NEAREST" else "AVERAGE",
    PREDICTOR = if (whole) "2" else "3"
  )
  if (length(gdal) > 0) {
    options[toupper(sub("=.*$", "", gdal))] <- sub("^[^=]*=", "", gdal)
  }
  options <- options[sort(names(options), method = "radix")]
  paste0(names(options), "=", unname(options))
}

# Legend of categorical layers --------------------------------------------------

# The legend of each layer of `x` (plan 0006, D-A6): `NULL` when no layer is
# categorical, else a list with one element per layer, `NULL` for a layer
# without categories and otherwise a list of
#   * `values`: the codes, sorted;
#   * `levels`: the labels of the active category, in the order of the codes;
#   * `levels_name`: the name of that label column;
#   * `dropped`: the other columns of the category table, which are not kept.
# Aborts through `raster_legend_check()`.
raster_legend <- function(x) {
  categorical <- terra::is.factor(x)
  if (!any(categorical)) {
    return(NULL)
  }
  layers <- names(x)
  lapply(seq_along(layers), function(i) {
    if (!categorical[[i]]) {
      return(NULL)
    }
    table <- terra::cats(x, layer = i)[[1]]
    # 1-based among the label columns, which follow the code column
    active <- terra::activeCat(x, layer = i) + 1L
    codes <- table[[1]]
    labels <- as.character(table[[active]])
    raster_legend_check(codes, labels, layers[[i]])
    by_code <- order(codes)
    list(
      values = as.double(codes[by_code]),
      levels = labels[by_code],
      levels_name = names(table)[[active]],
      dropped = setdiff(names(table)[-1], names(table)[[active]])
    )
  })
}

# Codes must be whole numbers, unique and not missing; labels must not be
# missing (plan 0006, AM6). Aborts with class `rcs_error_raster`.
raster_legend_check <- function(codes, labels, layer) {
  problems <- c(
    if (!is.numeric(codes) || anyNA(codes) || any(codes != round(codes), na.rm = TRUE)) {
      "The codes must be whole numbers, none missing."
    },
    if (anyDuplicated(codes) > 0) {
      paste0("Repeated code: ", paste(unique(codes[duplicated(codes)]), collapse = ", "), ".")
    },
    if (anyNA(labels)) {
      paste0(
        "No label for code: ",
        paste(unique(codes[is.na(labels)]), collapse = ", "), "."
      )
    }
  )
  if (length(problems) > 0) {
    problems <- gsub("([{}])", "\\1\\1", problems)
    raster_abort(
      c(
        "The categories of layer {.field {layer}} cannot be stored.",
        rlang::set_names(problems, rep("x", length(problems)))
      ),
      call = rlang::caller_env(2)
    )
  }
  invisible()
}

# One message for the whole raster, naming the columns of the category tables
# that are not kept.
raster_legend_inform <- function(legend, layers) {
  dropped <- lapply(legend, function(l) l$dropped)
  has <- lengths(dropped) > 0
  if (!any(has)) {
    return(invisible())
  }
  lines <- vapply(which(has), function(i) {
    paste0(layers[[i]], ": ", paste(dropped[[i]], collapse = ", "))
  }, character(1))
  lines <- gsub("([{}])", "\\1\\1", lines)
  rcs_inform(c(
    "Only the codes and the active labels of a categorical layer are stored. Dropped:",
    rlang::set_names(lines, rep("*", length(lines)))
  ))
}

# A copy of `x` without categories: its cells are the codes. `levels<-` works
# on a copy and reads no cells, so `x` and its source stay as they are.
raster_drop_levels <- function(x) {
  if (!any(terra::is.factor(x))) {
    return(x)
  }
  out <- x
  levels(out) <- NULL
  if (!identical(names(out), names(x))) {
    names(out) <- names(x)
  }
  out
}

# A copy of `x` without the time and units of its layers, which are not
# stored (plan 0006, AM10): terra would write them into the TIFF's metadata
# and into a side file. `time<-` works on a copy; `units<-` changes the
# object it is given, so it gets a copy made for it (`terra::deepcopy()`,
# which copies the cells of a raster in memory; only when units are set).
# `x` itself stays as it is.
raster_drop_time_units <- function(x) {
  out <- x
  if (!all(is.na(terra::time(out)))) {
    terra::time(out) <- NULL
  }
  if (any(nzchar(terra::units(out)))) {
    out <- terra::deepcopy(out)
    terra::units(out) <- ""
  }
  out
}

# Sets the categories recorded in `columns` (a columns specification, or
# `NULL`) on the layers of an opened raster (plan 0006, D-A7).
# `terra::set.cats()` works in place, writes nothing next to the file, and
# renames the layer to the label column, so the names are set again.
raster_set_legend <- function(r, columns) {
  if (is.null(columns)) {
    return(r)
  }
  layers <- names(r)
  for (i in seq_len(nrow(columns))) {
    r_type <- columns$r_type[[i]]
    layer <- match(columns$name[[i]], layers)
    if (is.null(r_type[["values"]]) || is.na(layer)) {
      next
    }
    label <- r_type[["levels_name"]] %||% "label"
    table <- data.frame(
      as.numeric(r_type[["values"]]), as.character(r_type[["levels"]]),
      stringsAsFactors = FALSE
    )
    names(table) <- c(if (identical(label, "value")) "code" else "value", label)
    invisible(terra::set.cats(r, layer = layer, value = table))
  }
  names(r) <- layers
  r
}

# Writing the file -------------------------------------------------------------

# `TRUE` when `x` is an unchanged view of one file: one source file for all
# layers, none in memory, no window, the layers in band order, and the
# dimensions, extent, layer count, layer names and CRS of the file itself (a
# CRS set in the session is not the file's: AM9).
raster_is_file_view <- function(x) {
  src <- terra::sources(x, bands = TRUE)
  file <- unique(src$source)
  if (length(file) != 1L || !nzchar(file) || any(terra::inMemory(x)) || any(terra::window(x))) {
    return(FALSE)
  }
  if (!identical(as.integer(src$bands), seq_len(terra::nlyr(x)))) {
    return(FALSE)
  }
  ref <- tryCatch(terra::rast(file), error = function(e) NULL)
  !is.null(ref) &&
    terra::nlyr(ref) == terra::nlyr(x) &&
    identical(dim(ref), dim(x)) &&
    identical(as.vector(terra::ext(ref)), as.vector(terra::ext(x))) &&
    identical(names(ref), names(x)) &&
    identical(terra::crs(ref), terra::crs(x))
}

# Writes `x` (without categories) as the COG `file` (plan 0006, D-A10, D-A11,
# AM3, AM4, AM7, AM9). `nodata` is one number, or `NULL` for none.
#   * GDAL copies the source file when `x` is an unchanged view of it, has no
#     scale or offset, and every value that marks missing cells in `x` (a
#     session flag and the source's NoData tag: terra applies both) is the
#     NoData value to write: `-a_nodata` only relabels, so any other marker
#     would turn missing cells into values. The copy must read back with
#     `names(x)`. A band without a description is named by terra after its
#     file, and the copy would be named after the staged file; such a source
#     is copied by way of a VRT that describes each band by its layer name
#     (`raster_named_vrt()`), in the subfolder `vrt/` next to `file`, removed
#     on exit. When that VRT cannot be made, terra writes the file.
#   * Otherwise terra writes it. Its temp folder is then the subfolder
#     `terra/` next to `file`, so that its intermediate file lies below the
#     staging folder; the option is restored and the subfolder removed on
#     exit, also after an error.
raster_write <- function(x, file, datatype, nodata, options) {
  translate <- raster_is_file_view(x) && !raster_is_scaled(x)
  if (translate) {
    bands <- raster_source_bands(x)
    markers <- c(raster_session_flag(x), bands$nodata)
    markers <- markers[!is.na(markers)]
    translate <- if (is.null(nodata)) length(markers) == 0 else all(markers == nodata)
  }
  source <- if (translate) unique(terra::sources(x))
  if (translate && !identical(bands$description, names(x))) {
    vrt_dir <- file.path(dirname(file), "vrt")
    dir.create(vrt_dir, recursive = TRUE, showWarnings = FALSE)
    on.exit(unlink(vrt_dir, recursive = TRUE), add = TRUE)
    source <- raster_named_vrt(source, file.path(vrt_dir, "source.vrt"), names(x))
  }
  if (!is.null(source)) {
    raster_write_translate(source, file, datatype, nodata, options)
  } else {
    terra_dir <- file.path(dirname(file), "terra")
    dir.create(terra_dir, recursive = TRUE, showWarnings = FALSE)
    old <- terra::terraOptions(print = FALSE)$tempdir
    on.exit(
      {
        terra::terraOptions(tempdir = old, print = FALSE)
        unlink(terra_dir, recursive = TRUE)
      },
      add = TRUE
    )
    terra::terraOptions(tempdir = terra_dir, print = FALSE)
    raster_write_terra(x, file, datatype, nodata, options)
  }
  invisible(file)
}

# A VRT of the file `source` at `vrt` whose bands are described by `names`,
# one per band: a few lines of XML that point to `source`, no cells. GDAL
# writes the VRT; the `<Description>` of each band is then set (replaced when
# there is one), with the names escaped for XML. Only the data bands count,
# those with a `band=` attribute: the band inside `<MaskBand>` has none.
# Returns `vrt`, or `NULL` when GDAL writes no VRT or its data bands are not
# one per name; the caller then leaves the file to terra.
raster_named_vrt <- function(source, vrt, names) {
  sf::gdal_utils("translate", source, vrt, options = c("-of", "VRT"), quiet = TRUE)
  if (!file.exists(vrt)) {
    return(NULL)
  }
  lines <- readLines(vrt, warn = FALSE, encoding = "UTF-8")
  lines <- lines[!grepl("^\\s*<Description>.*</Description>\\s*$", lines)]
  bands <- grep("<VRTRasterBand\\s[^>]*\\bband\\s*=", lines, perl = TRUE)
  if (length(bands) != length(names)) {
    return(NULL)
  }
  escaped <- enc2utf8(names)
  for (entity in list(c("&", "&amp;"), c("<", "&lt;"), c(">", "&gt;"))) {
    escaped <- gsub(entity[[1]], entity[[2]], escaped, fixed = TRUE)
  }
  described <- as.list(lines)
  described[bands] <- Map(
    function(line, name) c(line, paste0("    <Description>", name, "</Description>")),
    lines[bands], escaped
  )
  con <- file(vrt, open = "wb")
  on.exit(close(con), add = TRUE)
  writeLines(enc2utf8(unlist(described, use.names = FALSE)), con, useBytes = TRUE)
  vrt
}

# The COG `file` copied from the file `source` by `gdal_translate`, which
# writes no intermediate file. Without `-a_nodata` GDAL copies the source's
# tag; `none` writes no tag. `-norat` keeps category tables out of the TIFF;
# GDAL may still write them to a side file; side files are removed
# (`raster_remove_side_files()`). GDAL reports success for a source it cannot
# read, so the output is looked for.
raster_write_translate <- function(source, file, datatype, nodata, options) {
  sf::gdal_utils(
    "translate", source, file,
    options = c(
      "-of", "COG",
      "-ot", raster_gdal_types[[datatype]],
      "-a_nodata", if (is.null(nodata)) "none" else sprintf("%.17g", nodata),
      "-norat",
      as.vector(rbind("-co", options))
    ),
    quiet = TRUE
  )
  raster_remove_side_files(file)
  if (!file.exists(file)) {
    raster_abort(
      "GDAL cannot write the raster from {.path {source}}.",
      call = rlang::caller_env(2)
    )
  }
  invisible(file)
}

# The files GDAL and terra may write next to the TIFF `file`: `.aux.xml`
# (category tables, statistics) and `.aux.json` (terra, for the time and
# units of layers, should a raster still carry them). A dataset is one file,
# so they are removed.
raster_remove_side_files <- function(file) {
  unlink(paste0(file, c(".aux.xml", ".aux.json")))
  invisible()
}

# The COG `file` written by terra. The NoData value is always given: `NaN`
# stands for none (the file then shows `NoData Value=nan` and every value
# reads back); left out, terra would pick its own.
raster_write_terra <- function(x, file, datatype, nodata, options) {
  terra::writeRaster(
    x, file,
    filetype = "COG", datatype = datatype,
    NAflag = if (is.null(nodata)) NaN else nodata,
    gdal = options, overwrite = TRUE
  )
  raster_remove_side_files(file)
  if (!file.exists(file)) {
    raster_abort("terra did not write the raster.", call = rlang::caller_env(2))
  }
  invisible(file)
}

# Warns when the staging drive looks too small (plan 0006, D-A12): for a
# file-backed raster, less free space in `dir` than twice the size of the
# source files. No check for a raster in memory, nor when a size or the free
# space is unknown. Never aborts.
raster_check_space <- function(x, dir) {
  if (!raster_is_file_backed(x)) {
    return(invisible())
  }
  estimate <- 2 * sum(file.size(unique(terra::sources(x))))
  free <- disk_free(dir)
  if (is.na(estimate) || is.na(free) || free >= estimate) {
    return(invisible())
  }
  cli::cli_warn(
    c(
      "The staging drive may be too small to write this raster.",
      i = "Free: {format_bytes(free)}. Estimated need: {format_bytes(estimate)}.",
      i = "Staging folder: {.path {dir}}",
      i = "Set another folder with {.code options(rcs.staging_dir = )}."
    ),
    class = "rcs_warning_staging_space"
  )
  invisible()
}

# Staging and opening -----------------------------------------------------------

#' Stage a raster for writing
#'
#' Writes a Cloud Optimized GeoTIFF into the staging folder and describes it.
#' Implemented by I; called by E.
#'
#' The data type, the NoData value, the creation options and the way the file
#' is written follow the rules in the header of this file. Categorical layers
#' are written as codes; `x` itself is never changed. Columns of a category
#' table other than the codes and the active labels are dropped, with one
#' message for the whole raster. No manifest is written: the caller sets
#' `created` and `updated` of the entry and then builds the manifest from
#' `entry` and `files` (`new_manifest()`).
#'
#' @param x A `terra::SpatRaster` with a CRS.
#' @param dataset Full dataset name.
#' @param title,description Non-empty strings.
#' @param source,inputs Strings or `NA`.
#' @param columns Named character vector, layer name to description, or
#'   `NULL`.
#' @param history Dataset-level history setting: `TRUE`, `FALSE` or `NA`.
#' @param dir The staging folder.
#' @param datatype `NULL`, or one of `raster_types`.
#' @param nodata `NULL`, or one finite number that the data type can hold.
#' @param gdal `NULL`, or a character vector of `KEY=VALUE` creation options
#'   of GDAL's COG driver.
#' @return A list:
#'
#'   * `entry`: the entry, a one-row tibble made by `new_entry()`:
#'     `kind = "raster"`, `crs`, `bbox`, `rows` = number of cells,
#'     `n_files = 1`, `columns` with one row per layer whose `r_type` is
#'     `list(class = "SpatRaster", resolution = c(x, y), dim = c(nrow, ncol))`,
#'     followed by `nodata` (a number) when the file has a NoData value, and
#'     for a categorical layer by `values` (the codes), `levels` (their
#'     labels, in the order of the codes) and `levels_name` (the name of the
#'     label column); `created` and `updated` are set by the caller;
#'   * `files`: its file row, made by `new_file_rows()`, with
#'     `path = data_file_path(dataset, version, ext = "tif")`,
#'     `partition_values = "{}"`, the `bbox` and no cells;
#'   * `staged`: the local file, `file.path(dir, files$path)`.
#'
#'   The version is `version_hash("{}", md5)`. Two calls with the same raster
#'   give the same version. Aborts with class `rcs_error_raster` when `x` has
#'   no CRS, no values, repeated layer names, an unusable legend, values that
#'   `datatype` cannot hold, or layers whose NoData values differ; with class
#'   `rcs_error_argument` when `x` is not a `SpatRaster`, `columns` describes
#'   a layer `x` lacks, or `datatype`, `nodata` or `gdal` is not usable; and
#'   with the install hint when terra is missing. Warns with class
#'   `rcs_warning_staging_space` when the staging drive looks too small.
#' @noRd
raster_stage <- function(x, dataset, title, description,
                         source = NA_character_, inputs = NA_character_,
                         columns = NULL, history = NA,
                         dir = rcs_option("rcs.staging_dir"),
                         datatype = NULL, nodata = NULL, gdal = NULL) {
  check_terra()
  if (!inherits(x, "SpatRaster")) {
    cli::cli_abort(
      "{.arg x} must be a {.cls SpatRaster}, not {.obj_type_friendly {x}}.",
      class = "rcs_error_argument"
    )
  }
  check_dataset_name(dataset)
  check_string(title)
  check_string(description)
  crs <- raster_crs_json(x)
  if (is.na(crs)) {
    raster_abort(c(
      "The raster has no coordinate reference system.",
      i = "Set one with {.code terra::crs(x) <- ...}."
    ))
  }
  if (!all(terra::hasValues(x))) {
    raster_abort("The raster has no cell values.")
  }
  layers <- names(x)
  if (anyDuplicated(layers) > 0) {
    raster_abort(c(
      "Layer names must be unique.",
      x = "Repeated: {.field {unique(layers[duplicated(layers)])}}."
    ))
  }
  check_raster_descriptions(columns, layers)
  check_raster_arguments(datatype, nodata, gdal)

  legend <- raster_legend(x)
  datatype <- raster_datatype(x, datatype, nodata)
  nodata <- raster_nodata(x, datatype, nodata)
  datatype <- as.vector(datatype)
  options <- raster_gdal_options(datatype, gdal)
  raster_legend_inform(legend, layers)

  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  raster_check_space(x, dir)
  tmp_dir <- file.path(
    dir,
    paste0(".rcs-tmp-", md5_string(paste(dataset, Sys.getpid(), as.numeric(Sys.time()))))
  )
  dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)
  tmp <- file.path(tmp_dir, "part.tif")
  raster_write(raster_drop_time_units(raster_drop_levels(x)), tmp, datatype, nodata, options)
  left <- list.files(tmp_dir, all.files = TRUE, no.. = TRUE, recursive = TRUE)
  if (!identical(left, basename(tmp))) {
    cli::cli_abort(
      "Staging a raster must leave one file, not {.file {left}}.",
      .internal = TRUE
    )
  }
  types <- terra::datatype(terra::rast(tmp))

  md5 <- md5_file(tmp)
  bytes <- file.size(tmp)
  version <- version_hash("{}", md5)
  path <- data_file_path(dataset, version, ext = "tif")
  staged <- file.path(dir, path)
  dir.create(dirname(staged), recursive = TRUE, showWarnings = FALSE)
  if (file.exists(staged)) unlink(staged)
  if (!file.rename(tmp, staged)) {
    cli::cli_abort("Cannot move a staged file to {.path {staged}}.")
  }

  r_type <- list(
    class = "SpatRaster",
    resolution = as.double(terra::res(x)),
    dim = as.integer(c(terra::nrow(x), terra::ncol(x)))
  )
  if (!is.null(nodata)) {
    r_type$nodata <- as.double(nodata)
  }
  r_types <- lapply(seq_along(layers), function(i) {
    c(r_type, legend[[i]][c("values", "levels", "levels_name")])
  })
  description_of <- if (!is.null(columns)) unname(columns[layers])
  spec <- columns_spec(
    name = layers,
    type = types,
    r_type = r_types,
    description = description_of
  )
  bbox <- raster_bbox(x)
  now <- now_utc()
  files <- new_file_rows(
    dataset = dataset, version = version, path = path,
    partition_values = "{}", rows = terra::ncell(x), bytes = bytes, md5 = md5,
    bbox = as_bbox_row(bbox), created = now
  )
  entry <- new_entry(
    dataset = dataset, kind = "raster", title = title, description = description,
    version = version, n_files = 1, rows = terra::ncell(x), bytes = bytes,
    columns = columns_to_json(spec), source = source, inputs = inputs,
    crs = crs, bbox = bbox, history = history, created = now, updated = now
  )
  list(entry = entry, files = files, staged = staged)
}

#' Open a stored raster
#'
#' Implemented by I; called by F.
#'
#' The query's bounding box in the raster's CRS comes from `geo_covering()`
#' (the shape densified before any change of CRS). The crop snaps outwards
#' to whole cells, so a point or a line still gives the cells it touches. A
#' shape that crosses the antimeridian or holds a pole has no usable box
#' (`geo_covering()$bbox` is `NULL`); the raster is then returned uncropped.
#'
#' @param be The backend object of the location to read from.
#' @param path Relative path of the `.tif` file (`files$path`).
#' @param intersects `NULL`, or a query shape as for `geo_covering()`; the
#'   raster is then cropped to the bounding box of the shape in the raster's
#'   CRS.
#' @param columns `NULL`, or the columns specification of the entry
#'   (`columns_from_json(entry$columns)`). Each layer whose `r_type` holds a
#'   legend (`values`, `levels`, `levels_name`) gets its categories back,
#'   before any crop; without it the raster holds the codes. Nothing is
#'   written next to the file.
#' @return A `terra::SpatRaster` opened through `be_gdal_path(be, path)`, so
#'   that only the tiles needed are read; its data type and NoData value are
#'   those of the file. Aborts with class
#'   `rcs_error_raster` when the shape does not overlap the raster, and with
#'   the bullets of `be_auth_hint(be)` when GDAL cannot open the file (class
#'   `rcs_error_backend`); for a path in one of GDAL's virtual file systems
#'   only after its cache of folder listings was cleared
#'   (`terra::clearVSIcache()`) and a second attempt failed too. Counts one
#'   `file_open`.
#' @noRd
raster_open <- function(be, path, intersects = NULL, columns = NULL) {
  check_terra()
  gdal_path <- be_gdal_path(be, path)
  open <- function() terra::rast(gdal_path)
  r <- tryCatch(
    open(),
    error = function(e) {
      # GDAL keeps the folder listings of its virtual file systems (`/vsigs/`
      # and the like) for the whole process, so a file that appeared after
      # its folder was listed, such as the file of a version written since,
      # "does not exist" (plan 0006, AM12). The cache is cleared and the file
      # opened once more; rasters already open stay readable. Only after a
      # failure, so that an ordinary read makes no extra request.
      again <- if (startsWith(gdal_path, "/vsi")) {
        terra::clearVSIcache()
        tryCatch(open(), error = function(e) NULL)
      }
      if (!is.null(again)) {
        return(again)
      }
      cli::cli_abort(
        c("GDAL cannot open {.path {path}} in {.path {be$uri}}.", be_auth_hint_safe(be)),
        class = "rcs_error_backend", parent = e, call = NULL
      )
    }
  )
  trace_count("file_open", 1, location = be$uri, detail = path)
  r <- raster_set_legend(r, columns)
  if (is.null(intersects)) {
    return(r)
  }
  crs <- raster_crs_json(r)
  if (is.na(crs)) {
    raster_abort("The stored raster {.path {path}} has no coordinate reference system.")
  }
  query <- geo_covering(intersects, NA_integer_, crs)
  if (is.null(query$bbox)) {
    return(r)
  }
  terra::crop(r, raster_snap_extent(r, query$bbox, path), snap = "near")
}

# The query box snapped outwards to the raster's cells and clipped to its
# extent, as a `terra::ext()`. A box of zero width or height still covers
# the cells it touches. Aborts with class `rcs_error_raster` when the box
# does not overlap the raster.
raster_snap_extent <- function(r, bbox, path, call = caller_env()) {
  full <- raster_bbox(r)
  overlaps <- bbox[["xmin"]] <= full[["xmax"]] && bbox[["xmax"]] >= full[["xmin"]] &&
    bbox[["ymin"]] <= full[["ymax"]] && bbox[["ymax"]] >= full[["ymin"]]
  if (!isTRUE(overlaps)) {
    raster_abort(
      c(
        "The query does not overlap the raster {.path {path}}.",
        i = "Query box: {format_box(bbox)}.",
        i = "Raster extent: {format_box(full)}."
      ),
      call = call
    )
  }
  res <- terra::res(r)
  snap <- function(lo, hi, origin, step, n) {
    i0 <- min(max(floor((lo - origin) / step), 0), n)
    i1 <- min(max(ceiling((hi - origin) / step), 0), n)
    if (i1 <= i0) {
      if (i0 >= n) i0 <- n - 1 else i1 <- i0 + 1
    }
    origin + c(i0, i1) * step
  }
  x <- snap(bbox[["xmin"]], bbox[["xmax"]], full[["xmin"]], res[[1]], terra::ncol(r))
  y <- snap(bbox[["ymin"]], bbox[["ymax"]], full[["ymin"]], res[[2]], terra::nrow(r))
  terra::ext(x[[1]], x[[2]], y[[1]], y[[2]])
}

format_box <- function(bbox) {
  paste0(names(bbox), " ", signif(bbox, 6), collapse = ", ")
}
