# Build the website on this machine.
#
# Run from the project root:
#   source("pkgdown/deploy.R")
#
# The whole site, vignettes and articles included, is rendered here into
# `docs/`, which is committed. GitHub serves `docs/` of the `main` branch as
# it is: the site changes when `main` is pushed, and nothing is rendered or
# run on GitHub. The benchmark articles read the stored results in
# `bench/results/`; building the site runs no benchmark.
#
# After a change to the documentation: source this file, commit `docs/`
# together with the change, push.

site_build <- function() {
  pkgdown::build_site(preview = FALSE)
  site_clean()
}

site_clean <- function() {
  # pkgdown turns every Markdown file of the project root into a page; the
  # instructions for coding agents are not part of the website.
  drop <- c("CLAUDE.html", "CLAUDE.md")
  mentions <- function(x) Reduce(`|`, lapply(drop, grepl, x = x, fixed = TRUE))
  unlink(file.path("docs", drop))
  for (file in file.path("docs", c("sitemap.xml", "llms.txt"))) {
    if (file.exists(file)) {
      lines <- readLines(file, encoding = "UTF-8")
      writeLines(lines[!mentions(lines)], file, useBytes = TRUE)
    }
  }
  index <- file.path("docs", "search.json")
  if (file.exists(index)) {
    entries <- jsonlite::read_json(index)
    keep <- !vapply(entries, function(e) isTRUE(mentions(e$path)), logical(1))
    jsonlite::write_json(entries[keep], index, auto_unbox = TRUE)
  }
  site_scrub_paths()
  # Without this file GitHub would pass the site through Jekyll.
  file.create(file.path("docs", ".nojekyll"))
  invisible("docs")
}

site_scrub_paths <- function() {
  # Example output prints store locations below tempdir() and the path of the
  # local credentials file; both hold the local user name. The site shows a
  # neutral temporary folder and `~` for the home folder instead.
  temp <- normalizePath(dirname(tempdir()), winslash = "/", mustWork = FALSE)
  home <- Sys.getenv(if (.Platform$OS.type == "windows") "USERPROFILE" else "HOME")
  home <- normalizePath(home, winslash = "/", mustWork = FALSE)
  path_pattern <- function(path) {
    forms <- unique(c(
      path,
      gsub("/", "\\", path, fixed = TRUE),
      gsub("/", "\\\\", path, fixed = TRUE)
    ))
    paste0("(", paste(gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", forms), collapse = "|"), ")")
  }
  rules <- list(
    c(paste0(path_pattern(temp), "[/\\\\]+Rtmp[A-Za-z0-9]+"), "/tmp/Rtmp"),
    c(path_pattern(home), "~")
  )
  files <- list.files("docs", recursive = TRUE, full.names = TRUE)
  files <- files[grepl("\\.(html|md|json|txt|xml)$", files)]
  for (file in files) {
    lines <- readLines(file, encoding = "UTF-8", warn = FALSE)
    changed <- FALSE
    for (rule in rules) {
      hit <- grepl(rule[[1]], lines, ignore.case = TRUE)
      if (any(hit)) {
        lines[hit] <- gsub(rule[[1]], rule[[2]], lines[hit], ignore.case = TRUE)
        changed <- TRUE
      }
    }
    if (changed) writeLines(lines, file, useBytes = TRUE)
  }
  invisible(files)
}

if (sys.nframe() == 0L || identical(sys.function(1), source)) {
  site_build()
}
