# Simulated data. The package has no other data: tests, examples, vignettes
# and benchmarks all use these generators. Everything lies in open ocean.

# The box all simulated geometries lie in (EPSG:4326). An edge between two
# H3 resolution-0 cells runs through it, from longitude -29.4 at latitude 6
# to longitude -25.7 at latitude 9.
sim_box <- c(xmin = -30, ymin = 6, xmax = -24, ymax = 9)

# Number of rows of `rcs_sim_polygons()` with a fixed shape, and their ids.
sim_fixed <- c(
  rectangle = 1L, large = 2L, hole = 3L, thin = 4L,
  multi_1 = 5L, multi_2 = 6L, multi_3 = 7L, res0_edge = 8L, empty = 9L
)

check_sim_n <- function(n, min = 0, call = caller_env()) {
  if (!rlang::is_scalar_integerish(n, finite = TRUE) || n < min) {
    cli::cli_abort(
      "{.arg n} must be a whole number of at least {min}, not {.val {n}}.",
      class = "rcs_error_argument", call = call
    )
  }
  as.integer(n)
}

# Table -----------------------------------------------------------------------

#' Simulated table of daily sales
#'
#' A panel of invented shops selling invented products, with one column of
#' every type the package has to store faithfully. The rows are in random
#' order and are the same for the same `n` and `seed`; the random number
#' stream of the session is not changed.
#'
#' @param n Number of rows; zero gives an empty table with all columns.
#' @param seed Seed of the generator.
#'
#' @return A tibble with `n` rows and the columns:
#'
#'   * `shop_id` (integer), `date` (Date) and `product` (factor with the
#'     levels `p01` to `p20`, of which `p20` is never used): together they
#'     identify a row, and hold no missing values;
#'   * `year` (integer): the year of `date`, at least two different years,
#'     no missing values;
#'   * `qty` (integer), `price` (double), `promo` (logical);
#'   * `grade` (ordered factor `low` < `mid` < `high`);
#'   * `delivered` (Date);
#'   * `big` ([bit64::integer64], with small values and values above 2^53);
#'   * `wait` (difftime in hours);
#'   * `note` (character, with accented and non-Latin text);
#'   * `tags` (list of character vectors, some empty, some `NULL`);
#'   * `ts` (POSIXct in UTC) and `ts_local` (the same instants in the time
#'     zone of the session).
#'
#'   Every column from `qty` on holds missing values when `n` is positive.
#' @export
#' @examples
#' rcs_sim_table(5)
rcs_sim_table <- function(n = 1000, seed = 1) {
  n <- check_sim_n(n)
  withr::with_seed(seed, {
    shops <- 20L
    products <- 19L
    days <- max(730, 2 * ceiling(n / (shops * products)))
    combination <- sample.int(shops * products * days, n) - 1
    shop_id <- as.integer(combination %% shops) + 1L
    product <- as.integer((combination %/% shops) %% products) + 1L
    day <- combination %/% (shops * products)
    date <- as.Date("2023-01-01") + day
    levels <- sprintf("p%02d", 1:20)

    big <- bit64::as.integer64(sample.int(1000L, n, replace = TRUE))
    large <- which(stats::runif(n) < 0.5)
    big[large] <- bit64::as.integer64("9007199254740993") + big[large]

    notes <- c(
      "plain text", "two words", "caf\u00e9 cr\u00e8me", "na\u00efve fa\u00e7ade",
      "\u03b1\u03b2\u03b3 \u03b4\u03b5\u03b6", "\u0442\u0435\u043a\u0441\u0442",
      "\u6570\u636e", "\u0645\u062b\u0627\u0644", ""
    )
    tag_pool <- c("new", "sale", "bulk", "fragile")
    tags <- lapply(
      sample.int(4L, n, replace = TRUE) - 1L,
      function(k) tag_pool[seq_len(k)]
    )
    ts <- as.POSIXct("2023-01-01", tz = "UTC") + day * 86400 +
      sample.int(86400L, n, replace = TRUE) - 1

    out <- tibble::tibble(
      shop_id = shop_id,
      date = date,
      year = as.POSIXlt(date)$year + 1900L,
      product = factor(levels[product], levels = levels),
      qty = sample.int(50L, n, replace = TRUE),
      price = round(stats::runif(n, 0.5, 200), 2),
      promo = stats::runif(n) < 0.2,
      grade = factor(
        sample(c("low", "mid", "high"), n, replace = TRUE),
        levels = c("low", "mid", "high"), ordered = TRUE
      ),
      delivered = date + sample.int(10L, n, replace = TRUE),
      big = big,
      wait = as.difftime(round(stats::runif(n, 0, 72), 2), units = "hours"),
      note = sample(notes, n, replace = TRUE),
      tags = tags,
      ts = ts,
      ts_local = as.POSIXct(as.numeric(ts), origin = "1970-01-01", tz = "")
    )
    out$year <- as.integer(out$year)

    if (n > 0) {
      for (name in setdiff(names(out), c("shop_id", "date", "year", "product"))) {
        gaps <- sample.int(n, max(1L, round(0.03 * n)))
        if (name == "tags") {
          out$tags[gaps] <- list(NULL)
        } else {
          out[[name]][gaps] <- NA
        }
      }
    }
    out
  })
}

# Geometry helpers ------------------------------------------------------------

check_sim_h3 <- function(call = caller_env()) {
  rlang::check_installed("h3o", reason = "to place simulated shapes on H3 cell edges.", call = call)
}

# Degrees of longitude and latitude of a length in kilometres at a latitude.
km_to_lon <- function(km, lat) {
  km / (111.320 * cos(lat * pi / 180))
}

km_to_lat <- function(km) {
  km / 110.574
}

# Polygons from the vertices of regular shapes, vectorised. `angle` holds the
# directions of the vertices of one shape (radians); `rx`, `ry` the radii in
# degrees per feature.
sim_regular_polygons <- function(cx, cy, rx, ry, angle) {
  m <- length(cx)
  if (m == 0) {
    return(sf::st_sfc(crs = 4326))
  }
  angle <- c(angle, angle[[1]])
  k <- length(angle)
  x <- rep(cx, each = k) + rep(rx, each = k) * rep(cos(angle), times = m)
  y <- rep(cy, each = k) + rep(ry, each = k) * rep(sin(angle), times = m)
  # close every ring exactly
  first <- (seq_len(m) - 1L) * k + 1L
  x[first + k - 1L] <- x[first]
  y[first + k - 1L] <- y[first]
  sim_polygons_from_xy(x, y, rep(seq_len(m), each = k))
}

sim_polygons_from_xy <- function(x, y, feature) {
  sf::st_as_sfc(wk::wk_polygon(wk::xy(x, y, crs = "EPSG:4326"), feature_id = feature))
}

square_angles <- c(-3, -1, 1, 3) * pi / 4
hexagon_angles <- (0:5) * pi / 3

# Squares of a given side (km) centred on points.
sim_squares <- function(cx, cy, side_km) {
  half_diagonal <- side_km * sqrt(2) / 2
  sim_regular_polygons(
    cx, cy, km_to_lon(half_diagonal, cy), km_to_lat(half_diagonal), square_angles
  )
}

sim_ring <- function(x, y) {
  cbind(c(x, x[[1]]), c(y, y[[1]]))
}

# Longitude at which the resolution-0 cell changes along a parallel.
sim_res0_edge_lon <- function(lat) {
  cell <- function(lon) as.character(h3o::h3_from_xy(lat, lon, 0L))
  low <- sim_box[["xmin"]]
  high <- sim_box[["xmax"]]
  for (i in 1:40) {
    mid <- (low + high) / 2
    if (identical(cell(mid), cell(low))) {
      low <- mid
    } else {
      high <- mid
    }
  }
  (low + high) / 2
}

# One vertex of the resolution-5 cell of every point.
sim_cell_vertices <- function(lon, lat) {
  if (length(lon) == 0) {
    return(list(x = numeric(), y = numeric()))
  }
  cells <- h3o::h3_from_xy(lat, lon, 5L)
  coords <- sf::st_coordinates(sf::st_as_sfc(cells))
  feature <- coords[, ncol(coords)]
  first <- !duplicated(feature)
  list(x = coords[first, "X"], y = coords[first, "Y"])
}

sim_fixed_polygons <- function() {
  polygon <- function(...) sf::st_polygon(list(...))
  thin_lat <- 8.5
  thin_lon <- -29 + c(0, km_to_lon(300, thin_lat))
  thin_height <- km_to_lat(0.1)
  round_angle <- seq(0, 2 * pi, length.out = 13)[-13]
  round_radius <- 0.35 + 0.08 * stats::runif(12, -1, 1)
  small <- function(cx, cy) {
    half <- 0.002
    polygon(sim_ring(cx + half * c(-1, 1, 1, -1), cy + half * c(-1, -1, 1, 1)))
  }
  multi <- function(cx, cy, gap) {
    sf::st_multipolygon(list(small(cx, cy), small(cx + gap, cy + gap / 2)))
  }
  edge_lat <- 7.5
  edge_lon <- sim_res0_edge_lon(edge_lat)
  multi_x <- stats::runif(3, -29.5, -25.5)
  multi_y <- stats::runif(3, 6.3, 8.3)
  sf::st_sfc(
    # four vertices, more than 100 resolution-5 cells
    polygon(sim_ring(c(-29.8, -27.3, -27.3, -29.8), c(6.1, 6.1, 7.6, 7.6))),
    # many vertices, many cells
    polygon(sim_ring(-25.5 + round_radius * cos(round_angle), 8.2 + round_radius * sin(round_angle))),
    # a hole
    polygon(
      sim_ring(c(-26.6, -25.8, -25.8, -26.6), c(6.2, 6.2, 7.0, 7.0)),
      sim_ring(c(-26.35, -26.35, -26.05, -26.05), c(6.45, 6.75, 6.75, 6.45))
    ),
    # about 300 km long and 100 m wide
    polygon(sim_ring(
      thin_lon[c(1, 2, 2, 1)],
      thin_lat + thin_height * c(0, 0, 1, 1)
    )),
    multi(multi_x[[1]], multi_y[[1]], 0.01),
    multi(multi_x[[2]], multi_y[[2]], 0.05),
    multi(multi_x[[3]], multi_y[[3]], 0.5),
    # across the edge between two resolution-0 cells
    polygon(sim_ring(edge_lon + 0.01 * c(-1, 1, 1, -1), edge_lat + 0.01 * c(-1, -1, 1, 1))),
    sf::st_polygon(),
    crs = 4326
  )
}

sim_special_polygons <- function() {
  pole_lon <- seq(-180, 150, by = 30)
  sf::st_sfc(
    sf::st_polygon(list(sim_ring(c(179, -179, -179, 179), c(6, 6, 9, 9)))),
    sf::st_polygon(list(sim_ring(pole_lon, rep(88.5, length(pole_lon))))),
    crs = 4326
  )
}

# The geometries of an sfc as a bare list.
sfc_list <- function(x) {
  attributes(x) <- NULL
  x
}

# Areas and lengths on the sphere, whatever the session's s2 setting.
with_s2 <- function(code) {
  old <- suppressMessages(sf::sf_use_s2(TRUE))
  on.exit(suppressMessages(sf::sf_use_s2(old)))
  code
}

sim_points_in_box <- function(n, margin) {
  list(
    x = stats::runif(n, sim_box[["xmin"]] + margin, sim_box[["xmax"]] - margin),
    y = stats::runif(n, sim_box[["ymin"]] + margin, sim_box[["ymax"]] - margin)
  )
}

# Polygons --------------------------------------------------------------------

#' Simulated geospatial data
#'
#' Polygons, points, lines and a raster in a box of open ocean: longitude -30
#' to -24, latitude 6 to 9, EPSG:4326. The box is cut by an edge between two
#' H3 cells of resolution 0, so the shapes exercise every level of the H3
#' grid. The result is the same for the same arguments; the random number
#' stream of the session is not changed.
#'
#' @details
#' `rcs_sim_polygons()` returns rows of three groups, in this order of `id`:
#'
#' * `id` 1 to 9, fixed shapes: (1) a rectangle with four vertices that
#'   covers more than 100 H3 cells of resolution 5; (2) a large polygon with
#'   many vertices; (3) a large polygon with a hole; (4) a thin polygon about
#'   300 km long and 100 m wide; (5 to 7) multipolygons, the last with parts
#'   in different cells; (8) a polygon across the edge between the two
#'   resolution-0 cells; (9) an empty geometry.
#' * then `round(crossing_share * n)` small squares centred on a vertex of an
#'   H3 cell of resolution 5, so each crosses cell edges;
#' * then small squares and hexagons of 0.01 to 0.5 square kilometres at
#'   random places.
#'
#' With `special = TRUE`, two rows outside the box follow, both in open
#' ocean: `id` `n + 1`, a polygon across the antimeridian (longitude 179 to
#' -179, latitude 6 to 9), and `id` `n + 2`, a polygon around the north pole
#' (above latitude 88).
#'
#' For a projected case, transform the result:
#' `sf::st_transform(rcs_sim_polygons(), 32626)`.
#'
#' @param n Number of rows (without the two special rows); at least 20 for
#'   polygons, at least 0 for points and lines.
#' @param seed Seed of the generator.
#' @param crossing_share Share of rows built to cross H3 cell edges of
#'   resolution 5, between 0 and 0.5.
#' @param special Add the antimeridian and the pole polygon.
#'
#' @return `rcs_sim_polygons()`: an `sf` tibble with the columns `id`
#'   (integer), `area` (double, square kilometres, `NA` for the empty
#'   geometry), `cat` (character, `a` to `e`) and `geometry` (polygons and
#'   multipolygons). It needs the h3o package.
#' @export
#' @examplesIf rlang::is_installed("h3o")
#' rcs_sim_polygons(30)
#' rcs_sim_points(5)
#' rcs_sim_lines(5)
rcs_sim_polygons <- function(n = 1000, seed = 1, crossing_share = 0.1, special = FALSE) {
  n <- check_sim_n(n, min = 20)
  check_flag(special)
  if (!rlang::is_scalar_double(crossing_share) || is.na(crossing_share) ||
    crossing_share < 0 || crossing_share > 0.5) {
    cli::cli_abort(
      "{.arg crossing_share} must be a number between 0 and 0.5.",
      class = "rcs_error_argument"
    )
  }
  check_sim_h3()
  withr::with_seed(seed, {
    n_fixed <- length(sim_fixed)
    n_crossing <- min(round(crossing_share * n), n - n_fixed)
    n_small <- n - n_fixed - n_crossing

    fixed <- sim_fixed_polygons()

    near <- sim_points_in_box(n_crossing, margin = 0.3)
    vertex <- sim_cell_vertices(near$x, near$y)
    crossing <- sim_squares(vertex$x, vertex$y, stats::runif(n_crossing, 0.1, 0.5))

    centre <- sim_points_in_box(n_small, margin = 0.05)
    area <- stats::runif(n_small, 0.01, 0.5)
    hexagon <- stats::runif(n_small) < 0.5
    radius <- ifelse(hexagon, sqrt(area / (1.5 * sqrt(3))), sqrt(area / 2))
    # One list and one `st_sfc()` at the end: every `c()` or `[<-` on an sfc
    # computes all bounding boxes again.
    small <- vector("list", n_small)
    small[hexagon] <- sfc_list(sim_regular_polygons(
      centre$x[hexagon], centre$y[hexagon],
      km_to_lon(radius[hexagon], centre$y[hexagon]), km_to_lat(radius[hexagon]),
      hexagon_angles
    ))
    small[!hexagon] <- sfc_list(sim_regular_polygons(
      centre$x[!hexagon], centre$y[!hexagon],
      km_to_lon(radius[!hexagon], centre$y[!hexagon]), km_to_lat(radius[!hexagon]),
      square_angles
    ))

    geometry <- c(sfc_list(fixed), sfc_list(crossing), small)
    if (special) {
      geometry <- c(geometry, sfc_list(sim_special_polygons()))
    }
    geometry <- sf::st_sfc(geometry, crs = 4326)
    size <- with_s2(as.numeric(sf::st_area(geometry)) / 1e6)
    size[sf::st_is_empty(geometry)] <- NA_real_
    sf::st_sf(
      tibble::tibble(
        id = seq_along(geometry),
        area = size,
        cat = sample(letters[1:5], length(geometry), replace = TRUE)
      ),
      geometry = geometry
    )
  })
}

#' @rdname rcs_sim_polygons
#' @return `rcs_sim_points()`: an `sf` tibble with the columns `id`
#'   (integer), `value` (double), `cat` (character) and `geometry` (points
#'   spread evenly over the box).
#' @export
rcs_sim_points <- function(n = 1000, seed = 1) {
  n <- check_sim_n(n)
  withr::with_seed(seed, {
    at <- sim_points_in_box(n, margin = 0)
    sf::st_sf(
      tibble::tibble(
        id = seq_len(n),
        value = round(stats::rnorm(n, 100, 15), 3),
        cat = sample(letters[1:5], n, replace = TRUE)
      ),
      geometry = sf::st_as_sfc(wk::xy(at$x, at$y, crs = "EPSG:4326"))
    )
  })
}

#' @rdname rcs_sim_polygons
#' @return `rcs_sim_lines()`: an `sf` tibble with the columns `id` (integer),
#'   `length` (double, kilometres), `cat` (character) and `geometry` (lines of
#'   two to six vertices, up to some tens of kilometres long).
#' @export
rcs_sim_lines <- function(n = 1000, seed = 1) {
  n <- check_sim_n(n)
  withr::with_seed(seed, {
    vertices <- sample(2:6, n, replace = TRUE)
    feature <- rep(seq_len(n), times = vertices)
    start <- sim_points_in_box(n, margin = 0)
    total <- length(feature)
    first <- !duplicated(feature)
    step_x <- stats::runif(total, -0.05, 0.05)
    step_y <- stats::runif(total, -0.05, 0.05)
    step_x[first] <- 0
    step_y[first] <- 0
    walk <- function(origin, step) {
      origin[feature] + stats::ave(step, feature, FUN = cumsum)
    }
    x <- pmin(pmax(walk(start$x, step_x), sim_box[["xmin"]]), sim_box[["xmax"]])
    y <- pmin(pmax(walk(start$y, step_y), sim_box[["ymin"]]), sim_box[["ymax"]])
    geometry <- if (n == 0) {
      sf::st_sfc(crs = 4326)
    } else {
      sf::st_as_sfc(wk::wk_linestring(wk::xy(x, y, crs = "EPSG:4326"), feature_id = feature))
    }
    sf::st_sf(
      tibble::tibble(
        id = seq_len(n),
        length = with_s2(as.numeric(sf::st_length(geometry)) / 1000),
        cat = sample(letters[1:5], n, replace = TRUE)
      ),
      geometry = geometry
    )
  })
}

#' @rdname rcs_sim_polygons
#' @param nrow,ncol Size of the raster in cells.
#' @return `rcs_sim_raster()`: a `terra::SpatRaster` over the box with the
#'   layers `height` (double, smooth), `cover` (integer classes 1 to 5) and
#'   `moisture` (double, with missing cells). It needs the terra package.
#' @export
#' @examplesIf rlang::is_installed("terra")
#' rcs_sim_raster(nrow = 20, ncol = 20)
rcs_sim_raster <- function(seed = 1, nrow = 1000, ncol = 1000) {
  rlang::check_installed("terra", reason = "to simulate a raster.")
  nrow <- check_sim_n(nrow, min = 1)
  ncol <- check_sim_n(ncol, min = 1)
  withr::with_seed(seed, {
    cells <- nrow * ncol
    x <- rep(seq(0, 1, length.out = ncol), times = nrow)
    y <- rep(seq(1, 0, length.out = nrow), each = ncol)
    height <- 100 * sin(4 * pi * x) * cos(3 * pi * y) + stats::rnorm(cells, sd = 2)
    cover <- as.integer(cut(height, 5, labels = FALSE))
    moisture <- round(stats::runif(cells), 4)
    moisture[sample.int(cells, max(1L, cells %/% 100L))] <- NA_real_
    out <- terra::rast(
      nrows = nrow, ncols = ncol, nlyrs = 3,
      xmin = sim_box[["xmin"]], xmax = sim_box[["xmax"]],
      ymin = sim_box[["ymin"]], ymax = sim_box[["ymax"]],
      crs = "EPSG:4326"
    )
    terra::values(out) <- cbind(height, cover, moisture)
    names(out) <- c("height", "cover", "moisture")
    out
  })
}
