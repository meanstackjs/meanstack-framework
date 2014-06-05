path = require 'path'
fs = require 'fs'
vhosted = require 'vhosted'

module.exports = ($dir, $ext, $config, $injector, $emitter, $env) ->
  relativeAppDir = path.relative(__dirname, $dir.app)

  # Routing configuration
  if $config.router.strict
    server.enable 'strict routing'
  if $config.router.caseSensitive
    server.enable 'case sensitive routing'

  # Bootstrap
  boostrap = fs.existsSync "#{$dir.app}/bootstrap#{$ext}"
  if bootstrap
    bootstrap = require("#{relativeAppDir}/bootstrap")
  if bootstrap and bootstrap.vhosts?
    server = require('express')()
    vhosts = $injector.resolve bootstrap.vhosts
    server = vhosted server, $dir.project, vhosts
  else
    server = $injector.get '$app'

  $injector.register '$server', -> server

  # Start server
  listen = ->
    if bootstrap and bootstrap.server?
      server = $injector.resolve require("#{relativeAppDir}/bootstrap").server
    else
      http = require 'http'
      port = process.env.PORT or $config.port
      server = http.createServer(server).listen port, ->
        console.log 'Server listening on port ' + port
    server.on 'listening', ->
      fs.writeFileSync "#{$dir.project}/.tmp/reload", 'reload'
  if $env is 'production'
    $emitter.on 'mongoose-connected', ->
      listen()
  else
    listen()
