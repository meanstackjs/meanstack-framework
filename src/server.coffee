path = require 'path'

module.exports = (projectdir, appdir, appext, config, mean) ->
  relappdir = path.relative(__dirname, appdir)
  relprojectdir = path.relative(__dirname, projectdir)

  if config.middleware['vhosted']
    server = require('express')()

    # Routing configuration
    if config.router.strict
      server.enable 'strict routing'
    if config.router.caseSensitive
      server.enable 'case sensitive routing'

    vhosted = require 'vhosted'
    vhosts = mean.resolve require("#{relprojectdir}/vhosts#{appext}")
    server = vhosted server, projectdir, vhosts
    mean.register '$server', -> server
  else
    mean.register '$server', -> mean.get '$app'

  mean.resolve require("#{relappdir}/server")
