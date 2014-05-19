module.exports.project = require './project'
module.exports.plugin = require './plugin'
module.exports.server = ($dir, $ext, $config, $mean) ->
  require('./server')($dir.project, $dir.app, $ext, $config, $mean)
