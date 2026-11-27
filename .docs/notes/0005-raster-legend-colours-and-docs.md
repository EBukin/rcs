# Raster follow-up: user documentation, legend colours in the metadata, version bump

- **Date:** 2026-11-27
- **Author:** Eduard Bukin
- **Summary:** after part A of plan 0006 (version 0.0.0.9005), the owner asked for user documentation of the new raster functionality, storing the legend colours in the metadata, a version bump and a push; no measurement of windowed reads; planned as Part C of `.docs/plans/0006-raster-types-nodata-legend-primary-only.md`.

## Instruction (verbatim)

The owner's first message, after the report on part A:

> Okay, I think that we need to first update the documentation in accordance, so that it's clear for anyone who will use it, also for functional help, how to proceed with this information and with this functionality. Then we need to bump the version, push everything, code and update.
>
> As for the question that you posed: okay, so I'm not sure what you say about the streaming images. So you say that you can't understand if it works streaming, or what do you mean? So tell me. But it's okay for now. If it doesn't work, we could find some other solutions for streaming, or later.
>
> And as for the colors and legend, I think yes, we could store it somewhere in the messages, but in the metadata. So let's add this quickly.
>
> Okay, so report to me when it's done, or tell me what you'll be doing next first, and then if I confirm, then you will do it, implement, and report when it's done.

The owner's second message, after the proposal:

> Okay, do not make a window measures, it's fine. Implement whatever you propose. I agree with your assumptions and what you're doing.

## Note

- **Streaming.** Windowed reads from a bucket work and are tested on GCS: no whole-file download. Only the number of bytes one window fetches is unmeasured, because `rcs_trace()` counts bytes only in the package's own downloads. The owner decided not to measure it now.
- **Colours.** Taken from the raster's colour table (`terra::coltab()`), stored in the manifest next to the legend (in `r_type`) and restored by `store_read()`. No side file; the file's bytes and version do not change. A `.qml` file is not parsed.
- **Time and units of layers** stay unstored.
- **Documentation.** Function help and the vignette explain the raster arguments, class maps and the advice for large maps.
- **Version.** `0.0.0.9006`; plan 0005 then needs `0.0.0.9007`.
- **Decisions.** D-C1 to D-C8 are in plan 0006, Part C.
