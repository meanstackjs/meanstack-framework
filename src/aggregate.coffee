path = require('path')

module.exports = (collection, file, dir, value) ->
  chunks = path.relative(dir, file.replace(/\.[^.]+$/, '')).split(path.sep)
  cursor = collection
  for i in [0..chunks.length - 1] by 1
    if i < chunks.length - 1
      if not cursor[chunks[i]]?
        cursor = cursor[chunks[i]] = {}
      else
        cursor = cursor[chunks[i]]
    else
      cursor[chunks[i]] = value
