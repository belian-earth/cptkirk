# make a hex logo
library(devtools)
library(magick)
load_all()


tf2 <- tempfile(fileext = ".png")
blog <- magick::image_read("inst/hex/belian.png")
magick::image_read("inst/hex/captain-kirk.jpg") |>
  magick::image_crop("1600x1300+0+0") |>
  magick::image_annotate(
    "cptkirk",
    size = 90,
    color = "#DB830B",
    font = "Monaspace Krypton",
    location = "+870+880"
  ) |>
  #add logo
  magick::image_composite(
    blog,
    offset = "+940+100",
    operator = "dissolve",
    compose_args = "20%"
  ) |>
  magick::image_write(tf2)

t2 <- tempfile(fileext = ".png")
cropcircles::crop_hex(
  tf2,
  to = t2,
  border_size = 10,
  border_colour = "#74ac90ff",
  bg_fill = "#000000ff"
)

usethis::use_logo(t2)
