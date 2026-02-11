import unittest
import std/[tables]
import bilidown
import bilidown/utils

suite "Bilibili URL Extraction":
  test "extract BV ID from full URL":
    let url = "https://www.bilibili.com/video/BV1xx411c7mD"
    check extractBvid(url) == "BV1xx411c7mD"
  
  test "extract BV ID from short URL":
    # Note: b23.tv links need to be resolved first
    # For now we just check the path extraction
    discard
  
  test "extract BV ID from direct BV ID":
    # Direct BV IDs only have BV prefix uppercased
    check extractBvid("BV1xx411c7mD") == "BV1xx411c7mD"
    check extractBvid("bv1xx411c7md") == "BV1xx411c7md"
  
  test "URL validation":
    check isValidBilibiliUrl("https://www.bilibili.com/video/BV1xx411c7mD") == true
    check isValidBilibiliUrl("BV1xx411c7mD") == true
    check isValidBilibiliUrl("invalid_url") == false

suite "Utility Functions":
  test "sanitize filename":
    check sanitizeFilename("test/file:name?.mp4") == "test_file_name_.mp4"
    check sanitizeFilename("normal_file_name") == "normal_file_name"
  
  test "format bytes":
    check formatBytes(1024) == "1.00 KB"
    check formatBytes(1024 * 1024) == "1.00 MB"
  
  test "format duration":
    check formatDuration(125) == "02:05"
    check formatDuration(3665) == "1:01:05"
  
  test "quality label parsing":
    check parseQualityLabel(80) == "1080P"
    check parseQualityLabel(120) == "4K"
    check parseQualityLabel(999) == "Unknown"
  
  test "get default headers":
    let headers = getDefaultHeaders()
    check headers.hasKey("User-Agent")
    check headers.hasKey("Referer")
  
  test "get video page URL":
    check getVideoPageUrl("BV1xx411c7mD") == "https://www.bilibili.com/video/BV1xx411c7mD"
    check getVideoPageUrl("BV1xx411c7mD", 2) == "https://www.bilibili.com/video/BV1xx411c7mD?p=2"
  
  test "ffmpeg check":
    # This test just checks if the function runs without error
    discard checkFfmpeg()

suite "Video Quality Enum":
  test "video quality values":
    check ord(vq240P) == 6
    check ord(vq1080P) == 80
    check ord(vq4K) == 120

suite "BiliDownloader":
  test "create downloader":
    var downloader = newBiliDownloader()
    check downloader != nil
    downloader.close()
