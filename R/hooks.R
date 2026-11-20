# Hooks: the functions that one work package implements and another calls.
# Wave 0 fixes their signatures here as stubs that abort with class
# `rcs_error_not_implemented`. The work package that implements a function
# moves its documentation to its own file, keeps the signature and the return
# value exactly, and deletes the stub from this file. Changing a signature
# means updating the plan first.
#
# Conventions shared by all hooks:
#   * H3 cells inside the package are `bit64::integer64`, always. Cells given
#     by a user are hex strings, `integer64` or `h3o` `H3` vectors; a plain
#     numeric aborts (it cannot hold a cell).
#   * WKB geometry is a bare list of raw vectors, one per row, in the column
#     `geometry`; Arrow writes it as `binary`.
#   * A bounding box is a named double `c(xmin, ymin, xmax, ymax)`; a column of
#     boxes is a `bbox_df()`.
#   * A CRS travels as one PROJJSON string.
