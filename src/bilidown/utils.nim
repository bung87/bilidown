## Utility functions for bilidown

import std/[strutils, uri, osproc, tables]
import nregex

const
  BilibiliBaseUrl* = "https://www.bilibili.com"
  B23Url* = "https://b23.tv"
  UserAgent* = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  Referer* = "https://www.bilibili.com"
  Accept* = "*/*"
  AcceptLanguage* = "zh-CN,zh;q=0.9,en;q=0.8"
  AcceptEncoding* = "gzip, deflate, br"

type
  VideoFormat* = enum
    vfDash = "dash"
    vfFlv = "flv"
    vfMp4 = "mp4"

proc extractBvid*(url: string): string =
  ## Extract BV ID from Bilibili URL
  ## Supported formats:
  ## - https://www.bilibili.com/video/BVxxxx
  ## - https://b23.tv/BVxxxx
  ## - BVxxxx (direct BV ID)
  ## - bvxxxx (lowercase BV ID)
  
  let trimmedUrl = url.strip()
  
  # Direct BV ID
  if trimmedUrl.match(re"^(?i)bv[0-9a-zA-Z]{10}$"):
    return "BV" & trimmedUrl[2..^1]
  
  # Parse URL
  let parsedUrl = parseUri(trimmedUrl)
  let pathParts = parsedUrl.path.split('/')
  
  for part in pathParts:
    if part.match(re"^(?i)bv[0-9a-zA-Z]{10}$"):
      return "BV" & part[2..^1]
  
  # Also check query parameters for short links
  if parsedUrl.hostname in ["b23.tv", "www.b23.tv"]:
    # Short URL, need to resolve it
    for part in pathParts:
      if part.len > 0 and part.match(re"^(?i)bv[0-9a-zA-Z]{10}$"):
        return "BV" & part[2..^1]
  
  raise newException(ValueError, "Could not extract BV ID from URL: " & url)

proc getVideoPageUrl*(bvid: string, p: int = 1): string =
  ## Get the full video page URL from BV ID
  result = BilibiliBaseUrl & "/video/" & bvid
  if p > 1:
    result &= "?p=" & $p

proc getApiUrl*(bvid: string, cid: string = "", qn: int = 80): string =
  ## Construct the playurl API URL
  ## Note: This requires additional parameters and headers (including WBI signature)
  result = "https://api.bilibili.com/x/player/wbi/playurl?bvid=" & bvid
  if cid.len > 0:
    result &= "&cid=" & cid
  result &= "&qn=" & $qn & "&fnver=0&fnval=4048&fourk=1"

proc parseQualityLabel*(qn: int): string =
  ## Parse quality number to human-readable label
  case qn
  of 6: "240P"
  of 16: "360P"
  of 32: "480P"
  of 64: "720P"
  of 74: "720P60"
  of 80: "1080P"
  of 112: "1080P+"
  of 116: "1080P60"
  of 120: "4K"
  of 125: "HDR"
  of 126: "Dolby Vision"
  of 127: "8K"
  else: "Unknown"

proc getDefaultHeaders*(): Table[string, string] =
  ## Get default HTTP headers for Bilibili requests
  result = initTable[string, string]()
  result["User-Agent"] = UserAgent
  result["Referer"] = Referer
  result["Accept"] = Accept
  result["Accept-Language"] = AcceptLanguage

proc checkFfmpeg*(): bool =
  ## Check if ffmpeg is available in PATH
  let (output, exitCode) = execCmdEx("ffmpeg -version")
  discard output
  return exitCode == 0

proc getFfmpegVersion*(): string =
  ## Get ffmpeg version string
  let (output, exitCode) = execCmdEx("ffmpeg -version")
  if exitCode == 0:
    let lines = output.splitLines()
    if lines.len > 0:
      return lines[0]
  return ""

proc sanitizeFilename*(filename: string): string =
  ## Sanitize a filename by removing/replacing invalid characters
  result = filename
  let invalidChars = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
  for c in invalidChars:
    result = result.replace(c, "_")
  
  var sanitized = ""
  for c in result:
    if ord(c) >= 32 and ord(c) != 127:  # Skip control characters (0-31) and DEL (127)
      sanitized.add(c)
  result = sanitized
  
  # Limit length
  if result.len > 200:
    result = result[0..199]

proc formatBytes*(bytes: int64): string =
  ## Format bytes to human-readable string
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = bytes.float
  var unitIdx = 0
  
  while size >= 1024 and unitIdx < units.len - 1:
    size /= 1024
    unitIdx += 1
  
  result = formatFloat(size, ffDecimal, 2) & " " & units[unitIdx]

proc formatDuration*(seconds: int): string =
  ## Format seconds to MM:SS or HH:MM:SS
  let hours = seconds div 3600
  let mins = (seconds mod 3600) div 60
  let secs = seconds mod 60
  
  if hours > 0:
    result = $hours & ":" & ($mins).align(2, '0') & ":" & ($secs).align(2, '0')
  else:
    result = ($mins).align(2, '0') & ":" & ($secs).align(2, '0')

proc isValidBilibiliUrl*(url: string): bool =
  ## Check if a URL is a valid Bilibili video URL
  try:
    discard extractBvid(url)
    return true
  except:
    return false

proc extractCidFromUrl*(url: string): string =
  ## Extract CID (part ID) from URL if present
  let parsedUrl = parseUri(url)
  
  # Check query parameters
  if parsedUrl.query.len > 0:
    let pairs = parsedUrl.query.split('&')
    for pair in pairs:
      let kv = pair.split('=', 1)
      if kv.len == 2 and kv[0] == "p":
        return kv[1]
  
  return ""
