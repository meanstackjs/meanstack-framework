path = require 'path'
_ = require 'lodash'

# Resolve directories
module.exports.Renderer = class Renderer
  constructor: (@filename, @renderer, @cache, @locals) ->
    return
  render: (req, res, options, fn) ->
    options = options or {}
    if _.isFunction options
      fn = options
      options = {}
    fn = fn or (err, str) ->
      if err
        return req.next err
      res.send str
      return
    opts = {}
    opts = _.assign opts, @locals
    opts = _.assign opts, res.locals
    opts = _.assign opts, options
    opts.cache = if not opts.cache? \
      then @cache
      else opts.cache
    opts.filename = @filename
    try
      @renderer(@filename, opts, fn)
    catch err
      fn err
    return

module.exports.aggregate = (collection, file, dir, value) ->
  chunks = path.relative(dir, file.replace(/\.[^.]+$/, '')).split(path.sep)
  cursor = collection
  for i in [0..chunks.length - 1] by 1
    if i < chunks.length - 1
      if not collection[chunks[i]]?
        cursor = collection[chunks[i]] = {}
      else
        cursor = collection[chunks[i]]
    else
      cursor[chunks[i]] = value
