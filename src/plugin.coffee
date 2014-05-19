express = require 'express'
dependable = require 'dependable'
postrender = require 'express-postrender'
ect = require 'ect'
path = require 'path'
glob = require 'glob'
fs = require 'fs'
_ = require 'lodash'

utils = require './utils'

module.exports = (projectdir, appdir, appext, mean, config) ->
  relprojectdir = path.relative(__dirname, projectdir)
  relappdir = path.relative(__dirname, appdir)
  publicdir = path.join projectdir, 'public'
  if config?
    overrides = config

  # Get package and chainware
  pkg = require(path.join projectdir, 'package.json')
  appname = pkg.name
  chainware = require("#{relappdir}/chainware")
  dir =
    project: projectdir
    public: publicdir
    app: appdir

  # Register dependencies
  plugin = dependable.container()
  plugin.register '$plugin', plugin
  plugin.register '$mean', mean
  plugin.register '$env', process.env.NODE_ENV
  plugin.register '$dir', dir
  plugin.register '$ext', appext
  plugin.register '$name', appname
  plugin.register '$pkg', pkg

  # Basic configuration
  config = {}
  config.router = mean.get('$config').router

  # Register plugin
  plugins = mean.get '$plugins'
  plugins[appname] = plugin

  # Default views configuration
  config.views = {}
  config.views.dir = path.resolve "#{appdir}/views/"
  if process.env.NODE_ENV is 'production'
    config.views.cache = true
  else
    config.views.cache = false
  config.views.callback = (html) -> return html
  config.views.extension = 'html'
  plugin.register '$config', config

  # Config chainware
  if chainware.config?
    mean.resolve chainware.config

  # Override config
  if overrides?
    defaults = _.partialRight(_.assign, (a, b) ->
      if not a?
        return b
      return a
    )
    config = defaults(overrides, config)

  # Register database
  plugin.register '$connection', mean.get('$connection')
  plugin.register '$mongoose', mean.get('$mongoose')

  # Before app chainware
  if chainware.beforeApp?
    plugin.resolve chainware.beforeApp

  # Register app
  app = mean.get '$app'
  plugin.register '$app', -> app

  # Register assets
  assetfile = path.join projectdir, '.assets'
  if fs.existsSync assetfile
    assets = JSON.parse(fs.readFileSync(assetfile))
  else
    assets =
      js: {}
      css: {}
      other: {}
  mean.get('$assets')[appname] = assets
  plugin.register '$assets', assets

  # Set default view renderer
  if not config.views.engine?
    if config.views.cache
      engine = ect
        watch: true
        cache: true
        root: config.views.dir
    else
      engine = ect
        watch: false
        cache: false
        root: config.views.dir
    config.views.render = engine.render

  # Load views
  views = {}
  config.views = postrender(
    config.views,
    config.views.callback,
    'render'
  )
  globdir = path.resolve "#{config.views.dir}/**/*.#{config.views.extension}"
  glob globdir, sync: true, (err, files) ->
    if err
      console.log err
      process.exit 0
    for file in files
      renderer = new utils.Renderer(
        file,
        config.views.render,
        config.views.cache,
        app.locals
      )
      utils.aggregate views, file, config.views.dir, renderer
  plugin.register '$views', views

  # Load models
  dir = path.resolve "#{appdir}/models"
  glob "#{appdir}/models/**/*#{appext}", sync: true, (err, files) ->
    if err
      console.log err
      process.exit 0
    names = []
    for file in files
      name = path.basename(file).replace(path.extname(file), '').replace(/[-._]\w/g, ($1) ->
        return $1[1].toUpperCase();
      )
      name = name[0].toUpperCase() + name.substr(1)
      names.push(name)
      schema = require(file).schema
      plugin.register name + 'Schema', schema

    for i, file of files
      schema = plugin.get names[i] + 'Schema'
      plugin.register names[i] + 'Schema', -> schema

    for i, file of files
      model = require(file).model
      plugin.register names[i] + 'Model', model

    for i, file of files
      model = plugin.get names[i] + 'Model'
      plugin.register names[i] + 'Model', -> model

  # Load controllers
  dir = path.resolve "#{appdir}/controllers"
  glob "#{appdir}/controllers/**/*#{appext}", sync: true, (err, files) ->
    if err
      console.log err
      process.exit 0
    names = []
    for file in files
      name = path.basename(file).replace(path.extname(file), '').replace(/[-._]\w/g, ($1) ->
        return $1[1].toUpperCase();
      )
      name = name[0].toUpperCase() + name.substr(1)
      names.push(name)
      controller = require file
      plugin.register name + 'Ctrl', require(file)

    for i, file of files
      controller = plugin.get names[i] + 'Ctrl'
      plugin.register names[i] + 'Ctrl', -> controller

  # Before routing chainware
  if chainware.beforeRouting?
    plugin.resolve chainware.beforeRouting

  # Create router
  router = express.Router(config.router)
  plugin.register '$router', -> router

  # Load routes
  glob "#{appdir}/routes/**/*#{appext}", sync: true, (err, files) ->
    if err
      console.log err
      process.exit 0
    for file in files
      plugin.resolve {'$route': express.Router(config.router)}, require file

  # After routing chainware
  if chainware.afterRouting?
    plugin.resolve chainware.afterRouting

  # After app chainware
  if chainware.afterApp?
    plugin.resolve chainware.afterApp

  return {router: router, appname: appname}

module.exports.grunt = (projectdir, grunt) ->
  require('./grunt')(projectdir, grunt)

