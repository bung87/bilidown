## Bilibili Video Downloader using ChromeDevToolsProtocol
## 
## This module follows yt-dlp's approach:
## 1. Extract BV ID from URL
## 2. Get CID from video info API
## 3. Get stream URLs from playurl API (with WBI signature)
## 4. Download the streams and merge them with ffmpeg

import std/[asyncdispatch, json, os, strutils, tables, options, httpclient, times, algorithm]
import checksums/md5
import bilidown/utils
export utils

type
  VideoQuality* = enum
    vq240P = 6
    vq360P = 16
    vq480P = 32
    vq720P = 64
    vq720P60 = 74
    vq1080P = 80
    vq1080PPlus = 112
    vq1080P60 = 116
    vq4K = 120
    vqHDR = 125
    vqDolby = 126
    vq8K = 127

  VideoStream* = object
    baseUrl*: string
    backupUrls*: seq[string]
    bandwidth*: int
    codecs*: string
    quality*: VideoQuality
    qualityLabel*: string
    width*: int
    height*: int

  AudioStream* = object
    baseUrl*: string
    backupUrls*: seq[string]
    bandwidth*: int
    codecs*: string
    id*: string

  BiliVideoInfo* = object
    bvid*: string
    cid*: string
    aid*: string
    title*: string
    description*: string
    duration*: int
    cover*: string
    owner*: string
    videoStreams*: seq[VideoStream]
    audioStreams*: seq[AudioStream]

  DownloadError* = object of CatchableError

type
  # Video info API response
  VideoInfoResponse* = object
    code*: int
    message*: string
    data*: Option[VideoInfoData]

  VideoInfoData* = object
    bvid*: string
    aid*: int
    cid*: int
    title*: string
    desc*: string
    duration*: int
    pic*: string
    owner*: VideoOwner

  VideoOwner* = object
    name*: string

  # WBI API response  
  WbiResponse* = object
    code*: int
    message*: string
    data*: Option[WbiData]

  WbiData* = object
    wbi_img*: WbiImage

  WbiImage* = object
    img_url*: string
    sub_url*: string

  # Playurl API response
  PlayurlResponse* = object
    code*: int
    message*: string
    data*: Option[PlayurlData]

  PlayurlData* = object
    dash*: DashData
    durl*: Option[seq[JsonNode]]  # Alternative format

  DashData* = object
    video*: seq[DashVideo]
    audio*: seq[DashAudio]
    flac*: Option[JsonNode]  # Optional FLAC audio
    dolby*: Option[JsonNode]  # Optional Dolby audio

  DashVideo* = object
    baseUrl*: string
    backupUrl*: seq[string]
    bandwidth*: int
    codecs*: string
    id*: int
    width*: int
    height*: int
    quality*: int

  DashAudio* = object
    baseUrl*: string
    backupUrl*: seq[string]
    bandwidth*: int
    codecs*: string
    id*: string
  
  WbiKeyCache = object
    key: string
    ts: float
  
  # Json-compatible types for play info parsing (without Option wrapper for std/json)
  PlayInfoDashVideo* = object
    baseUrl*: string
    backupUrl*: seq[string]
    bandwidth*: int
    codecs*: string
    id*: int
    width*: int
    height*: int
  
  PlayInfoDashAudio* = object
    baseUrl*: string
    backupUrl*: seq[string]
    bandwidth*: int
    codecs*: string
    id*: int
  
  PlayInfoDash* = object
    video*: seq[PlayInfoDashVideo]
    audio*: seq[PlayInfoDashAudio]
    flac*: PlayInfoDashAudio
  
  PlayInfoDurlItem* = object
    url*: string
    backupUrl*: seq[string]
  
  PlayInfoData* = object
    dash*: PlayInfoDash
    durl*: seq[PlayInfoDurlItem]

type
  BiliDownloader* = ref object
    tempDir*: string
    wbiCache: WbiKeyCache
    httpClient: AsyncHttpClient

# WBI signature mixin key encoding table (from Bilibili's JS)
const MIXIN_KEY_ENC_TAB = [
  46'i8, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
  36, 20, 34, 44, 52
]

proc newBiliDownloader*(): BiliDownloader =
  ## Create a new BiliDownloader instance
  new result
  result.tempDir = getTempDir() / "bilidown"
  createDir(result.tempDir)
  result.wbiCache = WbiKeyCache(key: "", ts: 0)
  result.httpClient = newAsyncHttpClient()
  
  let headers = getDefaultHeaders()
  for key, value in headers:
    result.httpClient.headers[key] = value

proc close*(downloader: BiliDownloader) =
  ## Close the downloader and cleanup
  downloader.httpClient.close()

proc getWbiKey*(downloader: BiliDownloader): Future[string] {.async.} =
  ## Get WBI key using jsony for robust JSON parsing
  ## Keys are cached for 30 seconds
  
  let now = epochTime()
  if now < downloader.wbiCache.ts + 30 and downloader.wbiCache.key.len > 0:
    return downloader.wbiCache.key
  
  try:
    let content = await downloader.httpClient.getContent("https://api.bilibili.com/x/web-interface/nav")
    let response = content.parseJson.to(WbiResponse)
    
    # Handle API error codes
    if response.code != 0:
      var errorMsg = "WBI API error: " & $response.code
      if response.message.len > 0:
        errorMsg &= " - " & response.message
      echo "Warning: " & errorMsg
      # Continue with fallback instead of failing completely
    
    # Extract WBI data if available
    if response.data.isSome and response.data.get().wbi_img.img_url.len > 0:
      let wbiImg = response.data.get().wbi_img
      var lookup = ""
      
      # Extract key from img_url
      if wbiImg.img_url.len > 0:
        let parts = wbiImg.img_url.split("/")
        if parts.len > 0:
          let filename = parts[^1]
          lookup &= filename.split(".")[0]
      
      # Extract key from sub_url
      if wbiImg.sub_url.len > 0:
        let parts = wbiImg.sub_url.split("/")
        if parts.len > 0:
          let filename = parts[^1]
          lookup &= filename.split(".")[0]
      
      # Generate mixin key
      if lookup.len >= 64:
        var mixinKey = ""
        for i in MIXIN_KEY_ENC_TAB:
          if i.int < lookup.len:
            mixinKey.add(lookup[i.int])
        mixinKey = mixinKey[0..31]  # Take first 32 chars
        
        downloader.wbiCache.key = mixinKey
        downloader.wbiCache.ts = now
        return mixinKey
  except Exception as e:
    echo "Error getting WBI key with jsony: " & e.msg
  
  raise newException(DownloadError, "Failed to get WBI key with jsony")

type ParamSeq = ref seq[tuple[key, val: string]]

proc signWbi*(downloader: BiliDownloader, params: ParamSeq) {.async.} =
  ## Sign parameters with WBI key
  let mixinKey = await downloader.getWbiKey()
  
  # Add timestamp
  params[].add(("wts", $(epochTime().int)))
  
  # Filter params (remove chars: !'()*)
  var filteredParams: seq[tuple[key, val: string]]
  for pair in params[]:
    var filteredVal = ""
    for c in pair.val:
      if c notin "!'()*":
        filteredVal.add(c)
    filteredParams.add((pair.key, filteredVal))
  
  # Sort by key
  var sortedParams = filteredParams
  sortedParams.sort(proc(a, b: auto): int = cmp(a.key, b.key))
  
  # Build query string
  var queryParts: seq[string]
  for pair in sortedParams:
    queryParts.add(pair.key & "=" & pair.val)
  let query = queryParts.join("&")
  
  # Calculate MD5 hash
  let wRid = getMD5(query & mixinKey)
  params[].add(("w_rid", wRid))

proc getVideoInfo*(downloader: BiliDownloader, bvid: string): Future[BiliVideoInfo] {.async.} =
  ## Get video info using jsony for robust JSON parsing
  
  echo "Fetching video info for " & bvid & "..."
  
  let apiUrl = "https://api.bilibili.com/x/web-interface/view?bvid=" & bvid
  let content = await downloader.httpClient.getContent(apiUrl)
  
  try:
    let response = content.parseJson.to(VideoInfoResponse)
    
    # Handle API errors gracefully
    if response.code != 0:
      var errorMsg = "API error: " & $response.code
      if response.message.len > 0:
        errorMsg &= " - " & response.message
      raise newException(DownloadError, errorMsg)
    
    # Handle missing data gracefully
    if response.data.isNone:
      raise newException(DownloadError, "No video data in response")
    
    # Extract video data from Option
    let videoData = response.data.get()
    
    # Build result object with type-safe field access
    result.bvid = bvid
    result.cid = $videoData.cid
    result.aid = $videoData.aid
    result.title = videoData.title
    result.owner = videoData.owner.name
    result.duration = videoData.duration
    result.cover = videoData.pic
    result.description = videoData.desc
    
    if result.cid.len == 0:
      raise newException(DownloadError, "Could not get CID for video")
    
    echo "Found video: " & result.title
    echo "CID: " & result.cid
    
  except Exception as e:
    # Handle other exceptions
    raise newException(DownloadError, "Failed to get video info: " & e.msg)

proc parsePlayInfo*(response: JsonNode): tuple[videoStreams: seq[VideoStream], audioStreams: seq[AudioStream]] =
  ## Parse play info data using std/json with manual parsing for better error handling
  result.videoStreams = @[]
  result.audioStreams = @[]
  
  # Check response code
  if response["code"].getInt() != 0:
    echo "Warning: Playurl API returned error code: ", response["code"].getInt()
    if response["message"].kind != JNull:
      echo "Message: ", response["message"].getStr()
    return (videoStreams: @[], audioStreams: @[])
  
  # Check if data exists
  if not response.hasKey("data") or response["data"].kind == JNull:
    echo "Warning: No data section found in play info response"
    return (videoStreams: @[], audioStreams: @[])
  
  # Parse the data section manually for better error handling
  let dataNode = response["data"]
  
  # Parse dash data if available
  if dataNode.hasKey("dash") and dataNode["dash"].kind == JObject:
    let dashNode = dataNode["dash"]
    
    # Parse video streams
    if dashNode.hasKey("video") and dashNode["video"].kind == JArray:
      for videoItem in dashNode["video"]:
        var stream = VideoStream()
        
        if videoItem.hasKey("baseUrl"):
          stream.baseUrl = videoItem["baseUrl"].getStr()
        if videoItem.hasKey("backupUrl") and videoItem["backupUrl"].kind == JArray:
          for backup in videoItem["backupUrl"]:
            stream.backupUrls.add(backup.getStr())
        if videoItem.hasKey("bandwidth"):
          stream.bandwidth = videoItem["bandwidth"].getInt()
        if videoItem.hasKey("codecs"):
          stream.codecs = videoItem["codecs"].getStr()
        if videoItem.hasKey("id"):
          let qualityId = videoItem["id"].getInt()
          stream.quality = cast[VideoQuality](qualityId)
        if videoItem.hasKey("width"):
          stream.width = videoItem["width"].getInt()
        if videoItem.hasKey("height"):
          stream.height = videoItem["height"].getInt()
        
        stream.qualityLabel = $stream.width & "x" & $stream.height
        if stream.qualityLabel == "0x0":
          stream.qualityLabel = parseQualityLabel(ord(stream.quality))
        
        result.videoStreams.add(stream)
    
    # Parse audio streams
    if dashNode.hasKey("audio") and dashNode["audio"].kind == JArray:
      for audioItem in dashNode["audio"]:
        var stream = AudioStream()
        
        if audioItem.hasKey("baseUrl"):
          stream.baseUrl = audioItem["baseUrl"].getStr()
        if audioItem.hasKey("backupUrl") and audioItem["backupUrl"].kind == JArray:
          for backup in audioItem["backupUrl"]:
            stream.backupUrls.add(backup.getStr())
        if audioItem.hasKey("bandwidth"):
          stream.bandwidth = audioItem["bandwidth"].getInt()
        if audioItem.hasKey("codecs"):
          stream.codecs = audioItem["codecs"].getStr()
        if audioItem.hasKey("id"):
          stream.id = $audioItem["id"].getInt()
        
        result.audioStreams.add(stream)
    
    # Handle FLAC if present
    if dashNode.hasKey("flac") and dashNode["flac"].kind == JObject:
      let flacNode = dashNode["flac"]
      if flacNode.hasKey("baseUrl"):
        var stream = AudioStream()
        stream.baseUrl = flacNode["baseUrl"].getStr()
        if flacNode.hasKey("backupUrl") and flacNode["backupUrl"].kind == JArray:
          for backup in flacNode["backupUrl"]:
            stream.backupUrls.add(backup.getStr())
        if flacNode.hasKey("bandwidth"):
          stream.bandwidth = flacNode["bandwidth"].getInt()
        stream.codecs = "flac"
        stream.id = "flac"
        result.audioStreams.add(stream)
  
  # Parse durl format if present
  if dataNode.hasKey("durl") and dataNode["durl"].kind == JArray:
    for durlItem in dataNode["durl"]:
      var stream = VideoStream()
      if durlItem.hasKey("url"):
        stream.baseUrl = durlItem["url"].getStr()
      if durlItem.hasKey("backupUrl") and durlItem["backupUrl"].kind == JArray:
        for backup in durlItem["backupUrl"]:
          stream.backupUrls.add(backup.getStr())
      stream.qualityLabel = "direct"
      result.videoStreams.add(stream)
  
  return (videoStreams: result.videoStreams, audioStreams: result.audioStreams)


proc getPlayInfo*(downloader: BiliDownloader, bvid, cid: string, quality: int = 127): Future[JsonNode] {.async.} =
  ## Get play info using jsony for robust JSON parsing
  
  echo "Fetching stream URLs..."
  
  # Build params
  var params = new(seq[tuple[key, val: string]])
  params[].add(("bvid", bvid))
  params[].add(("cid", cid))
  params[].add(("fnval", "4048"))  # Request DASH format with all codecs
  params[].add(("fourk", "1"))
  params[].add(("qn", $quality))  # Request quality
  
  # Sign the request
  # await downloader.signWbi(params)
  
  # Build query string
  var queryParts: seq[string]
  for pair in params[]:
    queryParts.add(pair.key & "=" & pair.val)
  let query = queryParts.join("&")
  
  let playUrl = "https://api.bilibili.com/x/player/wbi/playurl?" & query
  
  let content = await downloader.httpClient.getContent(playUrl)
  

  let jsn = parseJson(content)
  
  # Check for API error codes (fallback logic)
  if jsn.hasKey("code"):
    let code = jsn["code"].getInt()
    if code != 0:
      if jsn.hasKey("data") and jsn["data"].kind == JObject:
        return jsn["data"]
      else:
        var errorMsg = "Playurl API error: " & $code
        if jsn.hasKey("message"):
          errorMsg &= " - " & jsn["message"].getStr()
        raise newException(DownloadError, errorMsg)
    
    if not jsn.hasKey("data"):
      raise newException(DownloadError, "Invalid playurl API response: " & content[0..min(200, content.len-1)])
    
    return jsn["data"]


proc fetchVideoInfo*(downloader: BiliDownloader, url: string): Future[BiliVideoInfo] {.async.} =
  ## Fetch video information and stream URLs using jsony for robust parsing
  
  # Extract BV ID from URL
  let bvid = extractBvid(url)
  echo "BV ID: " & bvid
  
  # Get video info (CID, title, etc.)
  result = await downloader.getVideoInfo(bvid)
  
  # Get stream URLs using jsony approach
  echo "Fetching stream URLs (jsony)..."
  
  # Build params
  var params = new(seq[tuple[key, val: string]])
  params[].add(("bvid", bvid))
  params[].add(("cid", result.cid))
  params[].add(("fnval", "4048"))  # Request DASH format with all codecs
  params[].add(("fourk", "1"))
  params[].add(("qn", "127"))  # Request quality
  
  # Sign the request
  # await downloader.signWbi(params)
  
  # Build query string
  var queryParts: seq[string]
  for pair in params[]:
    queryParts.add(pair.key & "=" & pair.val)
  let query = queryParts.join("&")
  
  let playUrl = "https://api.bilibili.com/x/player/wbi/playurl?" & query

  let playContent = await downloader.httpClient.getContent(playUrl)
  
  # Parse play info using jsony
  let (videoStreams, audioStreams) = parsePlayInfo(parseJson(playContent))
  
  result.videoStreams = videoStreams
  result.audioStreams = audioStreams
  
  echo "Found " & $result.videoStreams.len & " video streams"
  echo "Found " & $result.audioStreams.len & " audio streams"
  
  if result.videoStreams.len == 0:
    raise newException(DownloadError, "No video streams found. Video may require login or be region-restricted.")


proc downloadWithProgress*(client: AsyncHttpClient, url: string, outputPath: string) {.async.} =
  ## Download a file with progress indication
  
  # Set a callback to track download progress
  proc onProgressChanged(total, progress, speed: BiggestInt) {.async.} =
    if total > 0:
      let percent = int(progress * 100 div total)
      stdout.write("\rProgress: " & $percent & "%")
      stdout.flushFile()
  
  client.onProgressChanged = onProgressChanged
  
  let content = await client.getContent(url)
  writeFile(outputPath, content)
  echo "\nDownload complete: " & outputPath

proc mergeWithFfmpeg*(videoPath, audioPath, outputPath: string): bool =
  ## Merge video and audio using ffmpeg
  let cmd = "ffmpeg -i \"" & videoPath & "\" -i \"" & audioPath & 
            "\" -c copy -y \"" & outputPath & "\""
  
  echo "Merging with ffmpeg..."
  echo cmd
  
  let res = execShellCmd(cmd)
  return res == 0

proc downloadVideo*(downloader: BiliDownloader, videoInfo: BiliVideoInfo, 
                   outputDir: string = "./downloads",
                   quality: VideoQuality = vq1080P,
                   mergeStreams: bool = true): Future[string] {.async.} =
  ## Download a Bilibili video
  ## Returns the path to the downloaded file
  
  if videoInfo.videoStreams.len == 0:
    raise newException(DownloadError, "No video streams available")
  
  # Select best video stream based on quality preference
  var selectedVideo: VideoStream
  var foundQuality = false
  
  # Try to find exact quality match first
  for stream in videoInfo.videoStreams:
    if stream.quality == quality:
      selectedVideo = stream
      foundQuality = true
      break
  
  # If not found, use the best available quality
  if not foundQuality:
    selectedVideo = videoInfo.videoStreams[0]
    for stream in videoInfo.videoStreams:
      if ord(stream.quality) > ord(selectedVideo.quality):
        selectedVideo = stream
  
  echo "Selected video quality: " & selectedVideo.qualityLabel
  
  # Create output directory if it doesn't exist
  createDir(outputDir)
  
  # Download video
  let safeTitle = sanitizeFilename(videoInfo.title)
  let baseName = if safeTitle.len > 0: safeTitle else: videoInfo.bvid
  let videoPath = outputDir / baseName & "_video.m4s"
  
  echo "Downloading video stream..."
  await downloadWithProgress(downloader.httpClient, selectedVideo.baseUrl, videoPath)
  
  # Download audio if available
  var audioPath = ""
  if videoInfo.audioStreams.len > 0:
    let selectedAudio = videoInfo.audioStreams[0]  # Use first (usually best) audio stream
    audioPath = outputDir / baseName & "_audio.m4s"
    
    echo "Downloading audio stream..."
    await downloadWithProgress(downloader.httpClient, selectedAudio.baseUrl, audioPath)
  
  # Merge if audio exists
  if mergeStreams and audioPath != "":
    let outputPath = outputDir / baseName & ".mp4"
    if mergeWithFfmpeg(videoPath, audioPath, outputPath):
      # Clean up temp files
      removeFile(videoPath)
      removeFile(audioPath)
      return outputPath
    else:
      echo "Failed to merge with ffmpeg, returning separate files"
      return videoPath
  else:
    return videoPath

proc download*(downloader: BiliDownloader, url: string, 
              outputDir: string = "./downloads",
              quality: VideoQuality = vq1080P): Future[string] {.async.} =
  ## Download a Bilibili video by URL
  ## Returns the path to the downloaded file

  let videoInfo = await downloader.fetchVideoInfo(url)
  result = await downloader.downloadVideo(videoInfo, outputDir, quality)

# Convenience synchronous wrapper
proc downloadBilibiliVideo*(url: string, outputDir: string = "./downloads",
                           quality: VideoQuality = vq1080P): Future[string] {.async.} =
  ## Synchronous wrapper for downloading Bilibili videos
  var downloader = newBiliDownloader()
  defer: downloader.close()

  result = await downloader.download(url, outputDir, quality)

when isMainModule:
  # CLI interface
  import std/[parseopt]
  
  var url = ""
  var outputDir = "./downloads"
  var quality = vq1080P
  
  for kind, key, val in getOpt():
    case kind
    of cmdArgument:
      if url.len == 0:
        url = key
    of cmdLongOption, cmdShortOption:
      case key
      of "url", "u":
        url = val
      of "output", "o":
        outputDir = val
      of "quality", "q":
        try:
          let qn = parseInt(val)
          quality = cast[VideoQuality](qn)
        except:
          echo "Invalid quality value: " & val
          quit(1)
      of "help", "h":
        echo """
Bilibili Video Downloader

Usage: bilidown [options] <url>

Options:
  -u, --url <url>        Bilibili video URL or BV ID
  -o, --output <dir>     Output directory (default: ./downloads)
  -q, --quality <q>      Video quality number (default: 80)
  -h, --help             Show this help

Quality options:
  6   = 240P
  16  = 360P
  32  = 480P
  64  = 720P
  74  = 720P60
  80  = 1080P (default)
  112 = 1080P+
  116 = 1080P60
  120  = 4K
  125 = HDR
  126 = Dolby Vision
  127 = 8K

Examples:
  bilidown https://www.bilibili.com/video/BV1xx411c7mD
  bilidown BV1xx411c7mD -o ./videos -q 120
        """
        quit(0)
    of cmdEnd:
      discard
  
  if url.len == 0:
    echo "Error: Please provide a Bilibili URL or BV ID"
    echo "Usage: bilidown --url <url>"
    echo "Run 'bilidown --help' for more information"
    quit(1)
  
  # Check ffmpeg availability
  if not checkFfmpeg():
    echo "Warning: ffmpeg not found in PATH. Videos will not be merged."
    echo "Please install ffmpeg for best results."
  
  try:
    let outputPath = waitFor downloadBilibiliVideo(url, outputDir, quality)
    echo "Download complete: " & outputPath
  except Exception as e:
    echo "Error: " & e.msg
    quit(1)
