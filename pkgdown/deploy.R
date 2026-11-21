# Build the website on this machine and publish it.
#
# Run from the project root:
#   source("pkgdown/deploy.R")            # build and publish
#   site_build()                          # build only, into docs/
#
# The whole site, vignettes and articles included, is rendered here. GitHub
# receives finished HTML on the `gh-pages` branch and only serves it: no
# workflow runs there. The branch always holds one commit, the latest site.

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
  # Without this file GitHub would pass the site through Jekyll.
  file.create(file.path("docs", ".nojekyll"))
  invisible("docs")
}

site_publish <- function(remote = "origin", branch = "gh-pages") {
  git <- function(..., dir = "docs") {
    out <- system2("git", c("-C", dir, ...), stdout = TRUE, stderr = TRUE)
    status <- attr(out, "status")
    if (!is.null(status) && status != 0) {
      cli::cli_abort(c("git {.val {c(...)[1]}} failed.", x = "{out}"))
    }
    out
  }
  if (!file.exists(file.path("docs", "index.html"))) {
    cli::cli_abort("There is no built site in {.path docs}; run {.fn site_build} first.")
  }
  url <- git("remote", "get-url", remote, dir = ".")
  sha <- git("rev-parse", "--short", "HEAD", dir = ".")
  name <- git("config", "user.name", dir = ".")
  email <- git("config", "user.email", dir = ".")
  unlink(file.path("docs", ".git"), recursive = TRUE, force = TRUE)
  on.exit(unlink(file.path("docs", ".git"), recursive = TRUE, force = TRUE))
  git("init", "--quiet", "--initial-branch", branch)
  git("config", "user.name", shQuote(name))
  git("config", "user.email", email)
  git("config", "core.autocrlf", "false")
  git("add", "--all")
  git("commit", "--quiet", "-m", shQuote(paste("Site built from", sha)))
  git("push", "--force", "--quiet", url, paste0("HEAD:", branch))
  cli::cli_inform(c(v = "Published the site built from {.val {sha}} to {.val {branch}}."))
  invisible(sha)
}

if (sys.nframe() == 0L || identical(sys.function(1), source)) {
  site_build()
  site_publish()
}
