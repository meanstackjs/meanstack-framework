module.exports.project = require './project'

module.exports.plugin = require './plugin'

module.exports.server = (projectdir, appdir, appext, config, mean) ->
  require('./server')(projectdir, appdir, appext, config, mean)
