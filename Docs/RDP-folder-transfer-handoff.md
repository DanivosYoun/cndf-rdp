# RDP Folder Transfer Support Handoff

Target repository: `DanivosYoun/cndf-rdp`

## Summary

Mac-to-RDP clipboard and Finder drag/drop now accept folders as well as files.

The implementation recursively expands selected folders into file entries with Windows-style
relative paths, then advertises those entries through `FileGroupDescriptorW`. For example:

```text
Reports/
  2026/
    summary.pdf
```

is offered to Windows as:

```text
Reports\2026\summary.pdf
```

Windows receives normal `FileContentsRequest` range reads for each file and can recreate the folder
structure during paste.

## Scope

Supported:

- Finder copy/paste of a folder into the RDP session.
- Finder drag/drop of a folder into the RDP surface.
- Mixed file and folder selections.
- Nested folder contents.
- Korean filename/path component NFC normalization.

Current limitation:

- Empty folders are not advertised because the current clipboard path only transfers file content
  streams.
- macOS package descendants are skipped during enumeration to avoid unexpectedly expanding app
  bundles or package-style documents.

## Package Changes

- `Sources/FileTransferStaging/FileTransferStaging.swift`
  - Removed directory rejection for local paste inputs.
  - Added recursive folder enumeration.
  - Emits Windows-style relative transfer paths using `\`.
  - Normalizes every path component to NFC.
- `Tests/FileTransferStagingTests/FileTransferStagingTests.swift`
  - Covers nested folder staging.
  - Covers mixed file/folder staging.

## Verification

Automated:

```sh
swift test
```

Expected result: all 21 package tests pass.

Manual RDP verification:

1. Connect to a Windows RDP host.
2. Create a macOS folder with at least one nested subfolder and file.
3. Copy the folder in Finder, focus Explorer or Desktop in the RDP session, then paste.
4. Confirm the folder hierarchy appears on Windows.
5. Repeat by dragging the folder into the RDP surface.
6. Repeat with Korean folder/file names and confirm names remain composed on Windows.
