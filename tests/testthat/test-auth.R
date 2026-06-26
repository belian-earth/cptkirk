# Translation of GDAL-style auth settings to object_store options. All offline:
# .os_auth_opts() reads the environment / GDAL config, no network.

# Clear every GDAL var these tests touch so the host environment can't leak in.
local_clean_auth <- function(.local_envir = parent.frame()) {
  vars <- c("AWS_HTTPS", "AWS_S3_ENDPOINT", "AWS_NO_SIGN_REQUEST",
            "AWS_VIRTUAL_HOSTING", "AWS_REQUEST_PAYER",
            "AZURE_STORAGE_ACCOUNT", "AZURE_NO_SIGN_REQUEST",
            "AZURE_STORAGE_CONNECTION_STRING",
            "GS_NO_SIGN_REQUEST", "GS_ACCESS_KEY_ID", "GS_SECRET_ACCESS_KEY")
  withr::local_envvar(stats::setNames(as.list(rep(NA, length(vars))), vars),
                      .local_envir = .local_envir)
}

test_that("a clean environment yields no translated options", {
  local_clean_auth()
  expect_identical(.os_auth_opts(), character(0))
  kv <- .auth_kv()
  expect_identical(kv$keys, character(0))
  expect_identical(kv$vals, character(0))
})

test_that("AWS no-sign and virtual-hosting flags map name and value", {
  local_clean_auth()
  withr::local_envvar(AWS_NO_SIGN_REQUEST = "YES", AWS_VIRTUAL_HOSTING = "FALSE")
  o <- .os_auth_opts()
  expect_equal(o[["aws_skip_signature"]], "true")
  expect_equal(o[["aws_virtual_hosted_style_request"]], "false")
})

test_that("AWS_S3_ENDPOINT gains an https scheme by default", {
  local_clean_auth()
  withr::local_envvar(AWS_S3_ENDPOINT = "minio.example.com:9000")
  o <- .os_auth_opts()
  expect_equal(o[["aws_endpoint"]], "https://minio.example.com:9000")
  expect_false("aws_allow_http" %in% names(o))
})

test_that("AWS_HTTPS=NO gives an http endpoint and allows http", {
  local_clean_auth()
  withr::local_envvar(AWS_S3_ENDPOINT = "minio.example.com:9000", AWS_HTTPS = "NO")
  o <- .os_auth_opts()
  expect_equal(o[["aws_endpoint"]], "http://minio.example.com:9000")
  expect_equal(o[["aws_allow_http"]], "true")
})

test_that("an endpoint that already has a scheme is left alone", {
  local_clean_auth()
  withr::local_envvar(AWS_S3_ENDPOINT = "https://s3.example.com")
  expect_equal(.os_auth_opts()[["aws_endpoint"]], "https://s3.example.com")
})

test_that("AWS_REQUEST_PAYER=requester becomes a boolean", {
  local_clean_auth()
  withr::local_envvar(AWS_REQUEST_PAYER = "requester")
  expect_equal(.os_auth_opts()[["aws_request_payer"]], "true")
})

test_that("Azure account name is renamed and no-sign mapped", {
  local_clean_auth()
  withr::local_envvar(AZURE_STORAGE_ACCOUNT = "myaccount", AZURE_NO_SIGN_REQUEST = "YES")
  o <- .os_auth_opts()
  expect_equal(o[["azure_storage_account_name"]], "myaccount")
  expect_equal(o[["azure_skip_signature"]], "true")
})

test_that("GCS no-sign maps to google_skip_signature", {
  local_clean_auth()
  withr::local_envvar(GS_NO_SIGN_REQUEST = "ON")
  expect_equal(.os_auth_opts()[["google_skip_signature"]], "true")
})

test_that("GDAL boolean spellings all normalise", {
  expect_equal(.gdal_bool("Yes"), "true")
  expect_equal(.gdal_bool("on"), "true")
  expect_equal(.gdal_bool("1"), "true")
  expect_equal(.gdal_bool("FALSE"), "false")
  expect_equal(.gdal_bool("off"), "false")
  expect_equal(.gdal_bool("0"), "false")
  expect_true(is.na(.gdal_bool("")))
  expect_true(is.na(.gdal_bool("maybe")))
})

test_that("unsupported GCS HMAC keys warn", {
  local_clean_auth()
  withr::local_envvar(GS_ACCESS_KEY_ID = "GOOGabc")
  rlang::reset_warning_verbosity("ck_auth_gcs_hmac")
  expect_warning(.os_auth_opts(), "HMAC")
})

test_that("an unsupported Azure connection string warns", {
  local_clean_auth()
  withr::local_envvar(AZURE_STORAGE_CONNECTION_STRING = "DefaultEndpointsProtocol=https;...")
  rlang::reset_warning_verbosity("ck_auth_azure_connstr")
  expect_warning(.os_auth_opts(), "AZURE_STORAGE_CONNECTION_STRING")
})

test_that(".auth_kv splits a populated option set into parallel vectors", {
  local_clean_auth()
  withr::local_envvar(AWS_NO_SIGN_REQUEST = "YES", AWS_REQUEST_PAYER = "requester")
  kv <- .auth_kv()
  expect_type(kv$keys, "character")
  expect_type(kv$vals, "character")
  expect_length(kv$keys, length(kv$vals))
  expect_setequal(kv$keys, c("aws_skip_signature", "aws_request_payer"))
})
