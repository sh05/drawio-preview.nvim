--- Reading the diagram XML that draw.io embeds in its "editable PNG"
--- exports (the xmlpng format this plugin writes). The XML is stored
--- URL-encoded in a tEXt chunk keyed "mxfile"; walking the PNG chunk
--- list is a few lines of pure Lua, so no external tool is needed.
local M = {}

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

local function be32(s, pos)
  local a, b, c, d = s:byte(pos, pos + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function url_decode(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Extract the embedded diagram XML from PNG file contents.
--- Returns the XML string, or nil plus a human-readable reason.
function M.extract_xml(data)
  if data:sub(1, 8) ~= PNG_SIGNATURE then
    return nil, "not a PNG file"
  end
  local pos = 9
  local compressed = false
  -- Chunk layout: 4-byte big-endian length, 4-byte type, data, 4-byte CRC.
  while pos + 8 <= #data do
    local len = be32(data, pos)
    local ctype = data:sub(pos + 4, pos + 7)
    if pos + 11 + len > #data then
      break -- truncated chunk: better "no XML found" than a partial diagram
    end
    local body = data:sub(pos + 8, pos + 7 + len)
    if ctype == "tEXt" then
      local key, text = body:match("^([^%z]+)%z(.*)$")
      if key == "mxfile" then
        return url_decode(text)
      end
    elseif ctype == "zTXt" or ctype == "iTXt" then
      if body:match("^([^%z]+)%z") == "mxfile" then
        compressed = true -- present, but zlib-compressed; we can't inflate in pure Lua
      end
    elseif ctype == "IEND" then
      break
    end
    pos = pos + 12 + len
  end
  if compressed then
    return nil, "the embedded diagram XML is compressed (zTXt/iTXt), which is not supported"
  end
  return nil, "no embedded diagram XML (tEXt 'mxfile' chunk) found"
end

return M
