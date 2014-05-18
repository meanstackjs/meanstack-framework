express = require 'express'
mongoose = require 'mongoose'
dependable = require 'dependable'
postrender = require 'express-postrender'
ect = require 'ect'
path = require 'path'
glob = require 'glob'
fs = require 'fs'
_ = require 'lodash'

utils = require './utils'

module.exports = (projectdir, appdir, appext, config, built) ->
  relprojectdir = path.relative(__dirname, projectdir)
  relappdir = path.relative(__dirname, appdir)
  publicdir = path.join projectdir, 'public'
  if config?
    overrides = config

  # If set to false plugins won't be loaded
  if not built?
    built = true

  # Set default environment
  if not process.env.NODE_ENV?
    process.env.NODE_ENV = 'development'

  # Get package and chainware
  pkg = require(path.join projectdir, 'package.json')
  appname = pkg.name
  chainware = require("#{relappdir}/chainware")

  # Register dependencies
  mean = dependable.container()
  mean.register 'mean', mean
  mean.register 'environment', process.env.NODE_ENV
  mean.register 'projectdir', projectdir
  mean.register 'publicdir', publicdir
  mean.register 'appdir', appdir
  mean.register 'appext', appext
  mean.register 'appname', appname
  mean.register 'assets', {}
  mean.register 'plugins', {}

  # Basic configuration
  config = {}
  config.database = {}
  config.database.uri = 'mongodb://localhost/meanstackjs'
  config.database.options = {}
  config.secret = 'meanstackjs'
  config.mount = '/'
  config.port = 3000
  config.router =
    caseSensitive: false
    strict: false

  # Default assets configuration
  config.assets = {}
  config.assets.expiry = 0
  if process.env.NODE_ENV is 'production'
    config.assets.expiry = 1000 * 3600 * 24 * 365

  # Default middleware configuration
  config.middleware = {}
  config.middleware['vhosted'] = true
  config.middleware['compression'] = level: 9
  config.middleware['morgan'] = 'dev'
  config.middleware['cookie-parser'] = true
  config.middleware['body-parser'] = true
  config.middleware['express-validator'] = true
  config.middleware['method-override'] = true
  config.middleware['express-session'] =
    key: 'sid'
  config.middleware['connect-mongo'] =
    collection: 'session'
  config.middleware['view-helpers'] = true
  config.middleware['connect-flash'] = true
  config.middleware['serve-favicon'] = false
  config.middleware['errorhandler'] = true
  if process.env.NODE_ENV is 'production'
    config.middleware['morgan'] = false
    config.middleware['errorhandler'] = false

  # Default views configuration
  config.views = {}
  config.views.dir = path.resolve "#{appdir}/views/"
  if process.env.NODE_ENV is 'production'
    config.views.cache = true
  else
    config.views.cache = false
  config.views.callback = (html) -> return html
  config.views.extension = 'html'
  mean.register 'config', config

  # Config chainware
  if chainware.config?
    mean.resolve chainware.config

  # Override config
  config = mean.get 'config'
  if overrides?
    defaults = _.partialRight(_.assign, (a, b) ->
      if not a?
        return b
      return a
    )
    config = defaults(overrides, config)

  # Fix mount path
  if config.mount[config.mount.length - 1] isnt '/'
    config.mount += '/'

  # Register secret
  if config.middleware['cookie-parser']
    config.middleware['cookie-parser'] = config.secret
  if config.middleware['express-session']
    config.middleware['express-session']['secret'] = config.secret

  # Database
  if _.size(config.database.options) > 0
    connection = mongoose.createConnection config.database.uri, config.database.options
  else
    connection = mongoose.createConnection config.database.uri
  mean.register 'connection', connection
  mean.register 'mongoose', mongoose

  # Configure session store
  if config.middleware['express-session'] and \
    config.middleware['connect-mongo']
      if _.isBoolean config.middleware['connect-mongo']
        config.middleware['connect-mongo'] = {}
      config.middleware['connect-mongo']['db'] = connection.db
      store = new (require('connect-mongo')(require('express-session')))(
        config.middleware['connect-mongo']
      )
      if _.isBoolean config.middleware['express-session']
        config.middleware['express-session'] = {}
      config.middleware['express-session']['store'] = store

  # Before app chainware
  if chainware.beforeApp?
    mean.resolve chainware.beforeApp

  # Create app
  app = express()

  if config.router.strict
    app.enable 'strict routing'
  if config.router.caseSensitive
    app.enable 'case sensitive routing'

  mean.register 'app', -> app

  # Set default view renderer
  if not config.views.render?
    if config.views.cache
      engine = ect
        watch: true
        cache: true
        root: config.views.dir
        ext: ".#{config.views.extension}"
      app.locals.cache = 'memory'
    else
      engine = ect
        watch: false
        cache: false
        root: config.views.dir
        ext: ".#{config.views.extension}"
      app.locals.cache = false
    config.views.render = engine.render

  # Express view settings
  app.set 'view cache', config.views.cache
  app.set 'views', config.views.dir

  # Load views
  views = {}
  config.views = postrender(
    config.views,
    config.views.callback,
    'render'
  )
  app.set 'view engine', config.views.extension
  app.engine config.views.extension, config.views.render
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
  mean.register 'views', views

  # Load models
  models = {}
  dir = path.resolve "#{appdir}/models"
  glob "#{appdir}/models/**/*.{js,coffee}", sync: true, (err, files) ->
    if err
      console.log err
      process.exit 0
    for file in files
      utils.aggregate models, file, dir, mean.resolve require file
  mean.register 'models', models

  # Load controllers
  controllers = {}
  dir = path.resolve "#{appdir}/controllers"
  glob "#{appdir}/controllers/**/*.{js,coffee}", sync: true, (err, files) ->
    if err
      console.log err
      process.exit 0
    for file in files
      utils.aggregate controllers, file, dir, mean.resolve require file
  mean.register 'controllers', controllers

  # Load plugins
  plugins = {}
  if built
    vhosts = mean.resolve require(path.join projectdir, "vhosts#{appext}")
    regex = /\//
    for vhost in vhosts
      if vhost.plugin?
        vhost = _.assign(
          paths: []
        , vhost)
        if not _.isArray vhost.paths
          vhost.paths = [vhost.paths]
        if vhost.paths.length is 0
          vhost.paths.push '/'
        if regex.test vhost.plugin
          vhost.plugin = path.join(relprojectdir, vhost.plugin)
        else
          vhost.plugin = path.join(relprojectdir, 'node_modules', vhost.plugin)
        plugin = require(vhost.plugin)(mean, vhost.config)
        plugins[plugin.appname] = {}
        plugins[plugin.appname]['router'] = plugin.router
        plugins[plugin.appname]['paths'] = vhost.paths

  # Before middleware chainware
  if chainware.beforeMiddleware?
    mean.resolve chainware.beforeMiddleware

  # Register assets
  assets = mean.get('assets')
  assetfile = path.join projectdir, '.assets'
  if fs.existsSync assetfile
    assets[appname] = JSON.parse(fs.readFileSync(assetfile))
  else
    assets[appname] =
      js: {}
      css: {}
      other: {}

  locals = {}
  locals.appname = appname
  locals.assets = assets
  locals.mount = config.mount
  locals[appname] = {}
  locals[appname].appname = appname
  locals[appname].assets = assets[appname]
  locals[appname].module = (str) ->
    return "#{locals[appname].modulename}.#{str}"
  locals[appname].asset = (str) ->
    return "public/#{str}"
  locals[appname].resource = (str) ->
    return "public/js/#{str}"
  for k of mean.get('plugins')
    locals[k] = {}
    locals[k].appname = k
    locals[k].assets = assets[k]
    locals[k].module = (str) ->
      return "#{locals[k].modulename}.#{str}"
    locals[k].asset = (str) ->
      return "public/plugins/#{k}/#{str}"
    locals[k].resource = (str) ->
      return "public/plugins/#{k}/js/#{str}"
  app.use (req, res, next) ->
    res.removeHeader 'X-Powered-By'
    res.locals['mean'] = locals
    next()

  # Compression
  if chainware.beforeCompression?
    mean.resolve chainware.beforeCompression
  if config.middleware['compression']
    if not _.isBoolean config.middleware['compression']
      app.use require('compression')(config.middleware['compression'])
    else
      app.use require('compression')()
  if chainware.afterCompression?
    mean.resolve chainware.afterCompression

  # Morgan
  if chainware.beforeMorgan?
    mean.resolve chainware.beforeMorgan
  if config.middleware['morgan']
    if not _.isBoolean config.middleware['morgan']
      app.use require('morgan')(config.middleware['morgan'])
    else
      app.use require('morgan')()
  if chainware.afterMorgan?
    mean.resolve chainware.afterMorgan

  # Serve favicon
  if chainware.beforeServeFavicon?
    mean.resolve chainware.beforeServeFavicon
  if config.middleware['serve-favicon']
    if not _.isBoolean config.middleware['serve-favicon']
      app.use require('serve-favicon')(
        "#{publicdir}/favicon.ico",
        config.middleware['serve-favicon']
      )
    else
      app.use require('serve-favicon')("#{publicdir}/favicon.ico")
  if chainware.afterServeFavicon?
    mean.resolve chainware.afterServeFavicon

  # Express static
  if chainware.beforeStatic?
    mean.resolve chainware.beforeStatic
  app.use '/public', express.static(path.join(projectdir, 'public'),
    maxAge: config.assets.expiry)
  if chainware.afterStatic?
    mean.resolve chainware.afterStatic

  # Cookie parser
  if chainware.beforeCookieParser?
    mean.resolve chainware.beforeCookieParser
  if config.middleware['cookie-parser']
    if not _.isBoolean config.middleware['cookie-parser']
      app.use require('cookie-parser')(config.middleware['cookie-parser'])
    else
      app.use require('cookie-parser')()
  if chainware.afterCookieParser?
    mean.resolve chainware.afterCookieParser

  # Body parser
  if chainware.beforeBodyParser?
    mean.resolve chainware.beforeBodyParser
  if config.middleware['body-parser']
    app.use require('body-parser')()
  if chainware.afterBodyParser?
    mean.resolve chainware.afterBodyParser

  # Express validator
  if chainware.beforeExpressValidator?
    mean.resolve chainware.beforeExpressValidator
  if config.middleware['express-validator']
    if not _.isBoolean config.middleware['express-validator']
      app.use require('express-validator')(
        config.middleware['express-validator']
      )
    else
      app.use require('express-validator')()
  if chainware.afterExpressValidator?
    mean.resolve chainware.afterExpressValidator

  # Method override
  if chainware.beforeMethodOverride?
    mean.resolve chainware.beforeMethodOverride
  if config.middleware['method-override']
    app.use require('method-override')()
  if chainware.afterMethodOverride?
    mean.resolve chainware.afterMethodOverride

  # Express session
  if chainware.beforeExpressSession?
    mean.resolve chainware.beforeExpressSession
  if config.middleware['express-session']
    if not _.isBoolean config.middleware['express-session']
      app.use require('express-session')(config.middleware['express-session'])
    else
      app.use require('express-session')()
  if chainware.afterExpressSession?
    mean.resolve chainware.afterExpressSession

  # View helpers
  if chainware.beforeViewHelpers?
    mean.resolve chainware.beforeViewHelpers
  if config.middleware['view-helpers']
    app.use require('view-helpers')(appname)
  if chainware.afterViewHelpers?
    mean.resolve chainware.afterViewHelpers

  # Connect flash
  if chainware.beforeConnectFlash?
    mean.resolve chainware.beforeConnectFlash
  if config.middleware['connect-flash']
    app.use require('connect-flash')()
  if chainware.afterConnectFlash?
    mean.resolve chainware.afterConnectFlash

  # Before routing chainware
  if chainware.beforeRouting?
    mean.resolve chainware.beforeRouting

  # Create router
  router = express.Router(config.router)
  router.get '/mean.json', (req, res) ->
    obj = {}
    obj['appname'] = appname.replace('-', '.')
    obj['mount'] = config.mount
    obj['assets'] = assets
    res.json obj
  mean.register 'router', -> router

  # Before plugin routing chainware
  if chainware.beforePluginsRouting?
    mean.resolve chainware.beforePluginsRouting

  # Load plugin routes
  for n, obj of plugins
    for p in obj.paths
      app.use p, obj.router

  # After plugins routing chainware
  if chainware.afterPluginsRouting?
    mean.resolve chainware.afterPluginsRouting

  # Load routes
  glob "#{appdir}/routes/**/*.{js,coffee}", sync: true, (err, files) ->
    if err
      console.log err
      process.exit 0
    for file in files
      mean.resolve {route: express.Router(config.router)}, require file
  app.use router

  # After routing chainware
  if chainware.afterRouting?
    mean.resolve chainware.afterRouting

  # After middleware chainware
  if chainware.afterMiddleware?
    mean.resolve chainware.afterMiddleware

  # Error handler
  if chainware.beforeErrorHandler?
    mean.resolve chainware.beforeErrorHandler
  if config.middleware['errorhandler']
    app.use require('errorhandler')()
  if chainware.afterErrorHandler?
    mean.resolve chainware.afterErrorHandler

  # After app chainware
  if chainware.afterApp?
    mean.resolve chainware.afterApp

  return mean

module.exports.grunt = (projectdir, grunt) ->
  require('./grunt')(projectdir, grunt)
