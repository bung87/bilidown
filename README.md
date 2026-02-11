# Bilidown github ci badge

![CI](https://github.com/bung87/bilidown/actions/workflows/ci.yml/badge.svg)

A Bilibili video downloader built with Nim using direct API calls.

## Features

- Download Bilibili videos by URL or BV ID
- Direct API integration with Bilibili's official APIs
- Support for multiple video qualities (240P to 8K)
- DASH format support with separate video and audio streams
- Automatic merging of video and audio streams using ffmpeg
- Progress indication during download


## Requirements

- ffmpeg (for merging video and audio streams)

## Usage

### Command Line

```bash
# Download by URL
bilidown https://www.bilibili.com/video/BV1xx411c7mD

# Download by BV ID
bilidown BV1xx411c7mD

# Specify output directory
bilidown -u https://www.bilibili.com/video/BV1xx411c7mD -o ./videos

# Specify quality
bilidown -u BV1xx411c7mD -q 120  # 4K quality
```

### Quality Options

| Value | Quality   |
|-------|-----------|
| 6     | 240P      |
| 16    | 360P      |
| 32    | 480P      |
| 64    | 720P      |
| 74    | 720P60    |
| 80    | 1080P     |
| 112   | 1080P+    |
| 116   | 1080P60   |
| 120   | 4K        |
| 125   | HDR       |
| 126   | Dolby Vision |
| 127   | 8K        |

### Library Usage

```nim
import bilidown

# Simple synchronous download
let outputPath = downloadBilibiliVideo(
  "https://www.bilibili.com/video/BV1xx411c7mD",
  outputDir = "./downloads",
  quality = vq1080P
)
echo "Downloaded to: " & outputPath

# Async usage
import asyncdispatch

proc asyncDownload() {.async.} =
  let downloader = newBiliDownloader()
  try:
    let outputPath = await downloader.download(
      "https://www.bilibili.com/video/BV1xx411c7mD",
      "./downloads",
      vq1080P
    )
    echo "Downloaded to: " & outputPath
  finally:
    await downloader.close()

waitFor asyncDownload()
```

## How It Works

1. **Extract BV ID**: Parse the Bilibili URL to extract the BV ID
2. **Get Video Info**: Call Bilibili's video info API to get metadata and CID
3. **Get Stream URLs**: Call the playurl API to get DASH stream URLs with proper parameters
4. **Parse Response**: Use robust JSON parsing with std/json and manual field validation
5. **Download Streams**: Download video and audio streams with proper headers
6. **Merge**: Use ffmpeg to merge video and audio into a single MP4 file


## Key Implementation Details


### API Integration
- Direct calls to Bilibili's official APIs:
  - `/x/web-interface/view` for video metadata
  - `/x/player/wbi/playurl` for stream URLs
- Proper parameter handling with quality selection
- WBI signature support (when enabled)


## Limitations

- Some videos may require login (not yet supported)
- Region-restricted videos may not be downloadable
- ffmpeg is required for merging audio and video streams
- WBI signature is currently disabled but can be enabled

## License

MIT
