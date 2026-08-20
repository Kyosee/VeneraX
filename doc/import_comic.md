# Import Comic

## Introduction

VeneraX supports importing comics from local files.
However, the comic files must be in a specific format.

## Restore Local Downloads

If you migrated the app and kept the local download folder but lost `local.db`,
you can restore the local database by scanning the current local path.

- Open `Local` -> `Import` -> `Restore local downloads`.
- The app scans the current local storage path and rebuilds entries.
- It does not copy files or add favorites.
- Duplicates (same title or directory) are skipped.

Make sure the local storage path in Settings points to the folder that contains
the downloaded comics before running this.

## Comic Directory

A directory considered as a comic directory only if it follows one of the following two types of structure:

**Without Chapter**

```
comic_directory
├── cover.[ext]
├── img1.[ext]
├── img2.[ext]
├── img3.[ext]
├── ...
```

**With Chapter**

```
comic_directory
├── cover.[ext]
├── chapter1
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── chapter2
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── ...
```

The file name can be anything, but the extension must be a valid image extension.

The page order is determined by the file name. App will sort the files by name and display them in that order.

Cover image is optional. 
If there is a file named `cover.[ext]` in the directory, it will be considered as the cover image.
Otherwise, the first image will be considered as the cover image.

The name of directory will be used as comic title. And the name of chapter directory will be used as chapter title.

## Archive

VeneraX supports importing comics from archive files.

Currently, VeneraX supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`

Inside the archive, any of these layouts works:

- Images at the top level (one comic, no chapters).
- One subdirectory per chapter, each holding that chapter's images.
- One subdirectory per comic, when the top level has no images and no metadata
  file. Every subdirectory is then imported as its own comic.
- Archives nested inside the archive, so a folder of `.cbz` files zipped
  together imports every comic it contains.

Image extensions are matched case-insensitively, and pages are sorted in
natural order (`2.jpg` before `10.jpg`), so archives that don't zero-pad page
numbers keep their reading order.

A wrapping directory is transparent: `archive.cbz/comic_name/1.jpg` is treated
the same as `archive.cbz/1.jpg`.

`cover.[ext]` is used as the cover when present. `details.json`,
`ComicInfo.xml` and `metadata.json` are read for title, author, tags and
description when present; otherwise the file or directory name becomes the
title.
