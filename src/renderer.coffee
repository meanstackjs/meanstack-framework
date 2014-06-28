_ = require('lodash')

module.exports = class Renderer
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
