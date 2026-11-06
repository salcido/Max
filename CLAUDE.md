# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Max is a macOS (Cocoa, Objective-C/Objective-C++) app for ripping CDs and converting audio files between ~20 formats. It targets macOS 11+ on Apple silicon (arm64 only). There is no test suite or linter.

## Build

The third-party audio libraries (FLAC, lame, cdparanoia, TagLib, mp4v2, Monkey's Audio, etc.) are not checked in. `Frameworks/` is git-ignored and must be populated first:

```sh
Scripts/build_frameworks.sh        # fetches, patches, builds arm64 frameworks into Frameworks/
xcodebuild -project Max.xcodeproj -target Max -configuration Release CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
```

The script needs Xcode, cmake, curl, git, and bash >= 4 (re-execs under `/opt/homebrew/bin/bash`).

With a newer Xcode (verified with 27.2) the commands above fail; use these instead:

```sh
MIN_OS=12.0 bash Scripts/build_frameworks.sh   # `bash` on PATH must be >= 4 (e.g. MacPorts); /bin/bash is 3.2 and no Homebrew fallback may exist
xcodebuild -project Max.xcodeproj -target Max -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET=12.0 CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual
```

Why: Xcode 27.2 rejects deployment targets below macOS 12.0 (`MIN_OS` overrides the script's 11.0 default), and without `ARCHS=arm64` an x86_64 slice is built and fails to link against the arm64-only frameworks. The app lands in `build/Release/Max.app`. Build output goes to `build/`. The project uses explicit file references in `Max.xcodeproj/project.pbxproj`, so new source files must be added to the Xcode project.

## Architecture

Code is organized by directory, with a parallel class-per-format pattern in several of them:

- **Documents**: `CompactDisc/` (`CompactDiscDocument`, `Track`) and `CueSheet/` are NSDocument types for a CD or a cue sheet; `FileConversion/` is the file-conversion window. `Controllers/` holds app-level controllers (`ApplicationController`, `MediaController` for disc detection, `RipperController`/`EncoderController` which queue and schedule work).
- **Tasks → worker pipeline**: `Tasks/` holds `Task` subclasses that run on the main side and track progress/state. `RipperTasks/*` and `EncoderTasks/*` each spawn a worker thread and talk to it over a distributed-objects `NSConnection` (see `connectWithPorts:` in `RipperTask.m` / `EncoderTask.m`). The worker classes live in `Rippers/` and `Encoders/` and implement the `RipperMethods` / `EncoderMethods` protocols; the task is the worker's delegate and implements `RipperTaskMethods` / `EncoderTaskMethods`.
- **Adding a format** touches several places: an `Encoders/XEncoder` (worker) + `Tasks/EncoderTasks/XEncoderTask` (+ optionally a settings sheet in `Preferences/EncoderSettingsSheets/`), registered in the formats/encoder controllers; and for input, a `Decoders/XDecoder` subclassing `Decoder`. `.mm` files are used where C++ libs (Monkey's Audio, TagLib) are involved.
- **Rippers**: `BasicRipper` (fast, no error correction), `ComparisonRipper` (re-reads and compares for cache-based drives), `ParanoiaRipper` (cdparanoia). `Drive/` wraps low-level disc/TOC access.
- **Metadata**: `Metadata/AudioMetadata.mm` reads/writes tags across formats (TagLib/mp4v2); `MusicBrainz/` fetches disc info.
- **Preferences**: `Preferences/` has per-pane controllers; default values live as plists in `Preferences/Defaults/`.
- **Scripting**: `AppleScript/Max.sdef` defines the scripting dictionary (including the `convert` command, which accepts file lists); `Max.entitlements` includes the AppleScript entitlement. Localized resources are in `*.lproj` (en, de, es, fr, it, nb, nl).
- Sample-rate handling: encoders with limited supported rates (AAC, etc.) resample to a supported rate (see `Utilities/CoreAudioUtilities`, `Encoders/CoreAudioEncoder`).
