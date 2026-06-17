# Argument validation helpers shared by the public warp functions. Each aborts
# with a cli error attributed to the public caller (`call`), so the user sees
# e.g. "in `ck_warp()`" rather than an internal frame.

# A path/URL string, a character vector of them, or a cog_source handle.
.check_src <- function(x, arg = rlang::caller_arg(x), call = rlang::caller_env()) {
  if (inherits(x, "cog_source") || (is.character(x) && length(x) >= 1L && !anyNA(x))) {
    return(invisible(NULL))
  }
  cli::cli_abort(
    "{.arg {arg}} must be a path/URL string, a character vector of them, or a {.fn cog_source}.",
    call = call
  )
}

# NULL, or a length-`n` numeric vector with no NAs; optionally all > 0. `what`
# is the human-facing shape shown on failure, e.g. "c(xres, yres)".
.check_num_vec <- function(x, n, what, positive = FALSE,
                           arg = rlang::caller_arg(x), call = rlang::caller_env()) {
  if (is.null(x)) return(invisible(NULL))
  if (!is.numeric(x) || length(x) != n || anyNA(x)) {
    cli::cli_abort("{.arg {arg}} must be {.code {what}}.", call = call)
  }
  if (positive && any(x <= 0)) {
    cli::cli_abort("{.arg {arg}} values must be positive.", call = call)
  }
  invisible(NULL)
}

# NULL, or positive 1-based integer band indices.
.check_bands <- function(x, arg = rlang::caller_arg(x), call = rlang::caller_env()) {
  if (is.null(x)) return(invisible(NULL))
  if (!is.numeric(x) || anyNA(x) || any(x < 1) || any(x != as.integer(x))) {
    cli::cli_abort("{.arg {arg}} must be positive 1-based integer band indices.", call = call)
  }
  invisible(NULL)
}

# A tri-state speed knob: the string "auto", NULL, or a single positive number.
.check_speed <- function(x, arg = rlang::caller_arg(x), call = rlang::caller_env()) {
  if (is.null(x) || identical(x, "auto")) return(invisible(NULL))
  if (!(rlang::is_scalar_double(x) || rlang::is_scalar_integerish(x)) ||
        is.na(x) || x <= 0) {
    cli::cli_abort(
      "{.arg {arg}} must be {.val auto}, {.code NULL}, or a positive number (MB).",
      call = call
    )
  }
  invisible(NULL)
}

# NULL, a string (e.g. "ALL_CPUS"), or a positive integer thread count.
.check_threads <- function(x, arg = rlang::caller_arg(x), call = rlang::caller_env()) {
  if (is.null(x) || rlang::is_string(x)) return(invisible(NULL))
  if (!(rlang::is_scalar_integerish(x) && !is.na(x) && x >= 1)) {
    cli::cli_abort(
      "{.arg {arg}} must be {.code NULL}, a string (e.g. {.val ALL_CPUS}), or a positive integer.",
      call = call
    )
  }
  invisible(NULL)
}

# A character vector (rlang has no check_character in all supported versions).
.check_chr <- function(x, allow_null = FALSE, arg = rlang::caller_arg(x),
                       call = rlang::caller_env()) {
  if (is.null(x) && allow_null) return(invisible(NULL))
  if (!is.character(x)) {
    cli::cli_abort("{.arg {arg}} must be a character vector.", call = call)
  }
  invisible(NULL)
}

# NULL, a character vector, or a named list/vector of GDAL config options.
.check_config <- function(x, arg = rlang::caller_arg(x), call = rlang::caller_env()) {
  if (is.null(x) || is.character(x) || is.list(x)) return(invisible(NULL))
  cli::cli_abort(
    "{.arg {arg}} must be a named character vector or list of GDAL config options.",
    call = call
  )
}

# The cptkirk fetch / safety knobs common to both public functions.
.check_fetch_args <- function(overview, margin, io_concurrency, max_bytes,
                              sanitise, call = rlang::caller_env()) {
  rlang::check_number_whole(overview, min = 1, allow_null = TRUE, call = call)
  rlang::check_number_whole(margin, min = 0, call = call)
  rlang::check_number_whole(io_concurrency, min = 1, call = call)
  rlang::check_number_decimal(max_bytes, min = 1, allow_null = TRUE, call = call)
  rlang::check_bool(sanitise, call = call)
  invisible(NULL)
}
