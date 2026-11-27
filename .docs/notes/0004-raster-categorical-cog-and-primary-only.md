# Raster writes: small data types, nodata, COG options, class legend, disk-safe staging, primary-only writes

- **Date:** 2026-11-27
- **Author:** Eduard Bukin
- **Summary:** a downstream report that large categorical (`INT1U`) GeoTIFFs are inflated to `INT4S`, lose nodata and cannot carry a legend; confirmed by measurement on 2026-11-26; COG stays the only raster format; fix planned in `.docs/plans/0006-raster-types-nodata-legend-primary-only.md`.

## Instruction (verbatim)

The report as received (version 0.0.0.9004):

> # Raster writes: large categorical (INT1U) GeoTIFFs are inflated to INT4S, lose nodata, and cannot carry a class legend
>
> ## Context
>
> `ukrCadastreReharvest` needs to store about 18 national crop-type maps of Ukraine as raster datasets in the store (`gs://ukr-spat-data-v2`, local secondary at `GCS_BUCKET_LOCAL`). After writing, parcel zonal statistics read windows with `store_read(st, ds, intersects = ...)`.
>
> Source files (all alike):
>
> | Property | Value |
> |---|---|
> | CRS | EPSG:32636 (WGS 84 / UTM 36N) |
> | Resolution | 10 m |
> | Size | 88,823 × 132,874 cells (~11.8e9 cells), 1 band |
> | Data type | `INT1U` (Byte), class codes 1–27 |
> | Nodata | `0` means outside the map, but only one file declares it; the others have no NoData tag |
> | Layout | LZW, stripped (`Block=132874x1`), not tiled |
> | File size | 0.6–0.8 GB each |
>
> Class legends come as QGIS `.qml` files (code → label).
>
> ## Current behaviour (`R/raster.R`, `raster_stage()`, 0.0.0.9004)
>
> 1. **Data type is widened.** Layers that are all integer are always written as `INT4S`, anything else as `FLT8S`:
>    ```r
>    datatype <- if (all(terra::is.int(x))) "INT4S" else "FLT8S"
>    terra::writeRaster(x, tmp, filetype = "COG", datatype = datatype, overwrite = TRUE)
>    ```
>    A Byte map becomes 4 bytes per cell. Uncompressed, that is ~47 GB per map instead of ~11.8 GB, and the compressed COG is also larger.
> 2. **Nodata cannot be set.** No `NAflag` is passed, so there is no way to declare that `0` is missing. Readers then count `0` as a real class and zonal statistics get the coverage wrong.
> 3. **No control over GDAL creation options.** Compression, predictor, block size, overview resampling and `BIGTIFF` all fall back to GDAL / terra defaults. Overviews of a categorical map need `NEAREST` or `MODE`, never averaging.
> 4. **Categorical layers are refused** (`terra::is.factor()`), and nothing else carries the legend. The code → label table has to live in a separate table dataset, so it is not in the manifest and does not travel with the raster.
> 5. **Every write also goes to the secondary.** For ~18 maps of ~1 GB each this fills the local disk, with no option to keep large rasters in the primary only.
> 6. **Staging disk use is unknown and probably high (not measured).** `filetype = "COG"` goes through GDAL `CreateCopy`, so terra probably writes an intermediate file first. With `INT4S` that intermediate could reach tens of GB per map. A previous out-of-disk failure in this project (DuckDB spills during the `soil_depth` write) makes this a real risk on a machine with ~64 GB free.
>
> ## Expected behaviour / proposal
>
> - **Keep the smallest data type that holds the values.** Use the source's type when it is an integer type (`terra::datatype(x)`). Otherwise pick it from the value range: `INT1U` (0–255), `INT2U`/`INT2S`, `INT4S`, and floats as `FLT4S` unless double precision is requested. Allow an explicit `datatype` argument to `store_write()` for rasters.
> - **Nodata.** Add a `nodata` argument (written as the GDAL NoData tag via `NAflag`), recorded per layer in the manifest `columns`. Keep a source NoData tag when present.
> - **GDAL creation options.** Use defaults suited to cloud reads: `COMPRESS=DEFLATE` (or ZSTD), `PREDICTOR=2` for integers, `BLOCKSIZE=512`, `BIGTIFF=IF_SAFER`, and overviews with `OVERVIEW_RESAMPLING=NEAREST` (or `MODE`) for integer layers. Allow overrides with a `gdal = c(...)` argument.
> - **Legend in the manifest.** Accept categorical layers (or a `levels = data.frame(code, label, ...)` argument per layer). Store the codes in the TIFF, put the legend in the manifest `columns` (e.g. in `r_type$levels`), and restore it on `store_read()` with `terra::set.cats()`. No `.aux.xml` side files.
> - **Primary-only writes.** Add an option such as `locations = "primary"` (or a size threshold, in line with the 2 GB copy-on-read rule in plan 0005) so large rasters can skip the secondary and are read from the bucket through `/vsigs/`.
> - **Disk-safe staging.** Document or limit staging use: write the COG straight from a file-backed `SpatRaster` with `gdal_translate`-style streaming (`terra::writeRaster()` with `gdal = c("COPY_SRC_OVERVIEWS=YES", ...)`, or `sf::gdal_utils("translate", ...)`), honour `rcs.staging_dir` for terra / GDAL temp files, and check free space before starting.
>
> ## Acceptance criteria
>
> - Writing a 10 m national `INT1U` map gives a COG of type `Byte` with NoData `0`, tiled 512×512, with NEAREST/MODE overviews, and a size close to the source (≤ ~1 GB).
> - `store_read(st, ds, intersects = poly)` returns a `SpatRaster` whose type, NoData and categories match the source, with only the needed tiles fetched from `gs://`.
> - The manifest records per layer: data type, nodata, resolution, dimensions and the legend.
> - Peak staging disk use for one such map is documented and stays under ~2× the output size.
> - With `locations = "primary"`, a raster is not written to the secondary, and `store_status()` reports that as expected rather than as a mismatch.
> - Writes stay deterministic: the same input gives the same MD5 and version.
> - Tests: a small simulated `INT1U` raster with NoData and a legend round-trips through write and read with type, NoData and categories intact. An `INT4S` / `FLT4S` raster keeps its type.

The owner's instructions in the session:

> Should we allow for more options / format of saving data. What are the other important data formats?

> That is fine, we will not be addressing the TS gap now. Write the plan and commit it. Make sure that the plan could be executed by the parallel orchestrator that will be using subagents for implementing it and checking the results of implementation.

## Note

### Measured on 2026-11-26 (0.0.0.9004, terra 1.9.50, GDAL 3.12.1, own R session, simulated data under `tempdir()`)

A file-backed simulated `INT1U` raster, 25,000 × 25,000 cells, stripped, LZW, NoData 0 (source file 41.9 MB):

| Write | Time | Output | Intermediate file |
|---|---|---|---|
| Current: `writeRaster(filetype = "COG", datatype = "INT4S")` | 124 s | 118.6 MB | 2,500 MB (`spat_*.tif` in terra's temp folder, uncompressed `Int32`, 4 bytes per cell) |
| `writeRaster(filetype = "COG", datatype = "INT1U", NAflag = 0, gdal = <options>)` | 30 s | 6.9 MB | 15 MB (`spat_*.tif`, DEFLATE, `Byte`) plus 3 MB `.ovr.tmp` next to the output |
| `sf::gdal_utils("translate", -of COG, <options>)` | 15 s | 6.9 MB | 3 MB `.ovr.tmp` next to the output only |

Options: `COMPRESS=DEFLATE`, `PREDICTOR=2`, `BLOCKSIZE=512`, `BIGTIFF=IF_SAFER`, `OVERVIEW_RESAMPLING=NEAREST`.

- Point 6 of the report is confirmed. The current path writes an uncompressed 4-byte intermediate in terra's temp folder (R's `tempdir()`, not `rcs.staging_dir`): about 47 GB for one national map.
- With the options, the output is `Type=Byte`, `NoData Value=0`, `Block=512x512`, with overviews, and two writes give the same MD5.
- `terra::writeRaster()` peaks at about 3.6 times the output (intermediate + output + overview temp); `gdal_translate` at about 1.5 times.
- A categorical layer written with `writeRaster()` creates `<file>.aux.xml` and changes the TIFF's bytes. `terra::set.cats()` on an opened file creates no side file, and the categories survive `terra::crop()` in a quick check (`terra::freq()` showed labels).
- `terra::datatype()` is `""` for an in-memory raster and the source type (`"INT1U"`) for a file-backed one.
- `terra::NAflag()` returned `NaN` for a file whose GDAL NoData tag is `0`. It reports only a flag set in the session, so the source tag must be read another way (plan 0006, WP1).

### Decisions (owner, 2026-11-27)

- **COG stays the only raster format.** Variation is allowed inside it, through a `gdal = c("KEY=VALUE")` argument: compression (DEFLATE default; ZSTD, LZW, LERC by choice), block size, overview resampling. Lossy JPEG / WEBP are never a default.
- **Other formats are not added**: Zarr (many small objects per dataset; fits badly with one file, one MD5, one version), NetCDF / HDF5 (poor for cloud range reads), JPEG 2000 (slow, patchy support). Vector formats and point clouds are outside this question.
- **Time series are not addressed now.** The 18 annual maps are stored as one dataset per year. A multi-band stack or a cube format is a later question.
- The fix is planned in two parts: A (type, nodata, options, legend, staging; inside the raster code) and B (primary-only writes; after plan 0005, on which it builds).
