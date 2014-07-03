require('source-map-support').install()
dependable = require('dependable')
postrender = require('postrender')
path = require('path')
glob = require('glob')
events = require('events')
vhosted = require('vhosted')
fs = require('fs')
_ = require('lodash')

# Framework modules
aggregate = require('./aggregate')
resolve = require('./resolve')
Renderer = require('./renderer')

# Set default environment
if not process.env.NODE_ENV?
  process.env.NODE_ENV = 'development'

# Globals
containers = {}
injectors = {}
emitter = new events.EventEmitter()
connections = 0

emitter.on 'connected', ->
  connections--
  if connections is 0
    emitter.emit 'listen'

# Load application
load = (projectDir, appDir, appName) ->

  # Configure app name and directories
  pkg = require(path.join appDir.absolute, 'package.json')
  name = appName
  publicDir = path.join projectDir.absolute, 'public'
  srcDir = path.relative(projectDir.absolute, appDir.absolute).split(path.sep)
  srcDir[0] = 'src'
  srcDir = path.resolve(srcDir.join(path.sep))
  dir =
    project: projectDir.absolute
    app:
      public: path.join(publicDir, name)
      src: srcDir
      lib: appDir.absolute
    public: publicDir

  # Load chainware if available
  if fs.existsSync "#{appDir.absolute}/server/app.js"
    chainware = require("#{appDir.relative}/server/app")

  # Create container
  container = dependable.container()
  containers[name] = container

  injector =
    get: (name, overrides) ->
      if overrides?
        return container.get name, overrides
      return container.get name
    register: (name, fn) ->
      resolve containers, container, fn, name
    resolve: (cb) ->
      resolve containers, container, cb


  injectors[name] = injector

  container.register '$injectors', injectors

  # Register mongoose
  if pkg.dependencies?['mongoose']?
    mongoose = require("#{appDir.relative}/node_modules/mongoose")
    container.register '$mongoose', -> mongoose

  # Register swig
  if pkg.dependencies?['swig']?
    swig = require("#{appDir.relative}/node_modules/swig")
    container.register '$swig', -> swig

  # Register express
  if pkg.dependencies?['express']?
    express = require("#{appDir.relative}/node_modules/express")
    container.register '$express', -> express

  # Register dependencies
  container.register '$injector', injector
  container.register '$env', process.env.NODE_ENV
  container.register '$dir', dir
  container.register '$pkg', pkg
  container.register '$name', name
  container.register '$assets',
    js: {}
    css: {}
    other: {}

  # Basic configuration
  config = {}
  config.database = {}
  config.database.uri = 'mongodb://localhost/meanstackjs'
  config.database.options = {}
  config.secret = 'meanstackjs'
  config.mount = '/'
  config.router =
    caseSensitive: false
    strict: false

  # Assets configuration
  config.static = {}
  config.static.expiry = 0
  if process.env.NODE_ENV is 'production'
    config.static.expiry = 1000 * 3600 * 24 * 365

  # Middleware configuration
  config.middleware = {}
  config.middleware['vhosted'] = true
  config.middleware['compression'] =
    threshold : 0
    level: 9
  config.middleware['cookie-parser'] = true
  config.middleware['body-parser'] = true
  config.middleware['express-validator'] = true
  config.middleware['method-override'] = true
  config.middleware['express-session'] =
    key: 'sid'
  config.middleware['connect-mongo'] = true
  config.middleware['view-helpers'] = true
  config.middleware['connect-flash'] = true
  config.middleware['serve-favicon'] = false
  config.middleware['errorhandler'] = true
  if process.env.NODE_ENV is 'production'
    config.middleware['errorhandler'] = false

  # Default views configuration
  config.views = {}
  config.views.dir = path.resolve "#{appDir.absolute}/server/"
  if process.env.NODE_ENV is 'production'
    config.views.cache = true
  else
    config.views.cache = false
  config.views.callback = (html) -> return html
  config.views.extension = 'html'
  container.register '$config', config

  # Register assets
  assetFile = path.join projectDir.absolute, '.tmp/assets.json'
  if fs.existsSync assetFile
    assets = JSON.parse(fs.readFileSync(assetFile))
    container.register '$assets', assets
  assets = container.get '$assets'

  # Config chainware
  if chainware?.config?
    resolve containers, container, chainware.config

  # Load app
  return ->
    # Create app
    if express?
      app = express()
      container.register '$app', -> app
      router = express.Router(config.router)
      container.register '$router', -> router

      routeFactory = () ->
        express.Router(config.router)
      routeFactory.singleton = false
      injector.register '$route', routeFactory

    # Ensure leading and trailing slash in mount path
    if config.mount[0] isnt '/'
      config.mount = '/' + config.mount
    if config.mount[config.mount.length - 1] isnt '/'
      config.mount += '/'

    if express?
      app.locals.assets = assets
      app.locals.mount = config.mount
      app.locals.name = name

    # Register secret
    if config.middleware['cookie-parser']
      config.middleware['cookie-parser'] = config.secret
    if config.middleware['express-session']
      config.middleware['express-session']['secret'] = config.secret

    # Register event emitter
    container.register '$emitter', -> emitter

    # Database
    connections++
    connected = ->
      emitter.emit 'connected'
    if mongoose?
      if _.size(config.database.options) > 0
        connection = mongoose.createConnection(
          config.database.uri,
          config.database.options,
          connected
        )
      else
        connection = mongoose.createConnection(
          config.database.uri,
          connected
        )
      container.register '$connection', -> connection
    else
      connected()

    # Load chainware
    if chainware?.load?
      resolve containers, container, chainware.load

    # Set default view renderer
    if express?
      if not config.views.render? and swig?
        if config.views.cache
          engine = new swig.Swig
            loader: swig.loaders.fs(config.views.dir)
            cache: 'memory'
            varControls: ['{[', ']}']
          app.locals.cache = 'memory'
        else
          engine = new swig.Swig
            loader: swig.loaders.fs(config.views.dir)
            cache: false
            varControls: ['{[', ']}']
          app.locals.cache = false
        config.views.render = engine.renderFile

      if config.views.render?

        # Express view settings
        app.set 'view cache', config.views.cache
        app.set 'views', config.views.dir

        # Load views
        views = {}
        ###
        config.views = postrender(
          config.views,
          config.views.callback,
          'render'
        )
        ###
        app.set 'view engine', config.views.extension
        app.engine config.views.extension, config.views.render
        globDir = path.resolve "#{config.views.dir}/**/*.#{config.views.extension}"
        glob globDir, sync: true, (err, files) ->
          if err
            console.log err
            process.exit 0
          for file in files
            renderer = new Renderer(
              file,
              config.views.render,
              config.views.cache,
              app.locals
            )
            aggregate views, file, config.views.dir, renderer

        # Register views
        container.register '$views', views

    # Resolve components
    glob "#{appDir.absolute}/server/**/*.js", sync: true, (err, files) ->
      for file in files
        if path.relative(appDir.absolute, file) is "app.js"
          continue
        mdl = require file
        if mdl.register? and mdl.register is false
          continue
        if mdl.namespace?
          ns = mdl.namespace
        else
          ns = ''
        _.forOwn mdl, (prop, key) ->
          if prop.register? and prop.register is false or key is 'namespace' or key is 'alias'
            return
          if ns.length > 0
            key = "#{ns}.#{key}"
          if prop.namespace?
            key = "#{prop.namespace}.#{key}"
          resolve containers, container, prop, key

    # Init chainware
    if chainware?.init?
      resolve containers, container, chainware.init

    if not express?
      return container

    # Configure session store
    if pkg.dependencies?['connect-mongo']? and pkg.dependencies?['express-session']?
      if config.middleware['express-session'] and \
        config.middleware['connect-mongo']
          if _.isBoolean config.middleware['connect-mongo']
            config.middleware['connect-mongo'] = {}
          config.middleware['connect-mongo']['db'] = container.get('$connection').db
          cm = require("#{appDir.relative}/node_modules/connect-mongo")
          es = require("#{appDir.relative}/node_modules/express-session")
          store = new (cm(es))(config.middleware['connect-mongo'])
          if _.isBoolean config.middleware['express-session']
            config.middleware['express-session'] = {}
          config.middleware['express-session']['store'] = store

    # Configure router
    if config.router.strict
      app.enable 'strict routing'
    if config.router.caseSensitive
      app.enable 'case sensitive routing'

    # Middleware chainware
    if chainware?.middleware?
      resolve containers, container, chainware.middleware

    # Modify headers
    app.use (req, res, next) ->
      res.removeHeader 'X-Powered-By'
      next()

    # Compression
    if chainware?['compression']?
      container.resolve chainware['compression']
    if pkg.dependencies?['compression']? and config.middleware['compression']
      m = require("#{appDir.relative}/node_modules/compression")
      if not _.isBoolean config.middleware['compression']
        app.use m(config.middleware['compression'])
      else
        app.use m()

    # Serve favicon
    if chainware?['serve-favicon']?
      container.resolve chainware['compression']
    if pkg.dependencies?['serve-favicon']? and config.middleware['serve-favicon']
      m = require("#{appDir.relative}/node_modules/serve-favicon")
      if not _.isBoolean config.middleware['serve-favicon']
        app.use m(
          "#{dir.app.public}/favicon.ico",
          config.middleware['serve-favicon']
        )
      else
        app.use m("#{dir.app.public}/favicon.ico")

    # Express static
    if chainware?.static?
      resolve containers, container, chainware.static

    if config.static
      app.use "/public", express.static("#{publicDir}",
        maxAge: config.static.expiry)

    # Cookie parser
    if chainware?['cookie-parser']?
      container.resolve chainware['cookie-parser']
    if pkg.dependencies?['cookie-parser']? and config.middleware['cookie-parser']
      m = require("#{appDir.relative}/node_modules/cookie-parser")
      if not _.isBoolean config.middleware['cookie-parser']
        app.use m(config.middleware['cookie-parser'])
      else
        app.use m()

    # Body parser
    if chainware?['body-parser']?
      container.resolve chainware['body-parser']
    if pkg.dependencies?['body-parser']? and config.middleware['body-parser']
      m = require("#{appDir.relative}/node_modules/body-parser")
      app.use m()

    # Express validator
    if chainware?['express-validator']?
      container.resolve chainware['express-validator']
    if pkg.dependencies?['express-validator']? and config.middleware['express-validator']
      m = require("#{appDir.relative}/node_modules/express-validator")
      if not _.isBoolean config.middleware['express-validator']
        app.use m(config.middleware['express-validator'])
      else
        app.use m()

    # Method override
    if chainware?['method-override']?
      container.resolve chainware['method-override']
    if pkg.dependencies?['method-override']? and config.middleware['method-override']
      m = require("#{appDir.relative}/node_modules/method-override")
      app.use m()

    # Express session
    if chainware?['express-session']?
      container.resolve chainware['express-session']
    if pkg.dependencies?['express-session']? and config.middleware['express-session']
      m = require("#{appDir.relative}/node_modules/express-session")
      if not _.isBoolean config.middleware['express-session']
        app.use m(config.middleware['express-session'])
      else
        app.use m()

    # View helpers
    if chainware?['view-helpers']?
      container.resolve chainware['view-helpers']
    if pkg.dependencies?['view-helpers']? and config.middleware['view-helpers']
      m = require("#{appDir.relative}/node_modules/view-helpers")
      app.use m(name)

    # Connect flash
    if chainware?['connect-flash']?
      container.resolve chainware['connect-flash']
    if pkg.dependencies?['connect-flash']? and config.middleware['connect-flash']
      m = require("#{appDir.relative}/node_modules/connect-flash")
      app.use m()

    # Dependencies chainware
    if chainware?.dependencies?
      container.resolve chainware.dependencies

    # Resolve routes
    if chainware?.main?
      resolve containers, container, chainware.main
    app.use '/', container.get '$router'

    # Error handler
    if chainware?['errorhandler']?
      container.resolve chainware['errorhandler']
    if pkg.dependencies?['errorhandler']? and config.middleware['errorhandler']
      m = require("#{appDir.relative}/node_modules/errorhandler")
      app.use m()

    # Run chainware
    if chainware?.run?
      resolve containers, container, chainware.run

    return container

module.exports.load = (dirname, filename) ->
  projectDir =
    absolute: path.resolve(dirname)
  projectDir.relative = path.relative(__dirname, projectDir.absolute)

  apps = {}
  glob "#{projectDir.absolute}/lib/*/", {sync: true}, (err, appDirs) ->
    for appDir in appDirs
      appDir =
        absolute: path.resolve(appDir)
      appDir.relative = path.relative(__dirname, appDir.absolute)
      appName = path.basename(appDir.absolute)
      apps[appName] = load(projectDir, appDir, appName)

  # Load main
  main = fs.existsSync "#{projectDir.absolute}/lib/main.js"
  if not main
    console.error('Main file not found.')
    process.exit(0)
  main = require("#{projectDir.relative}/lib/main")

  # Configure containers
  if main.config?
    main.config(containers)

  # Bootstrap
  for name, app of apps
    app()

  return containers

module.exports.listen = (dirname, filename) ->
  projectDir =
    absolute: path.resolve(dirname)
  projectDir.relative = path.relative(__dirname, projectDir.absolute)

  connectionsEstablished = 0

  # Load express
  pkg = require("#{projectDir.relative}/package.json")
  if pkg.dependencies?['express']?
    app = require("#{projectDir.relative}/node_modules/express")()
  else
    console.error('Express is not installed.')
    process.exit(0)

  # Load main
  main = fs.existsSync "#{projectDir.absolute}/lib/main.js"
  if not main
    console.error('Main file not found.')
    process.exit(0)
  main = require("#{projectDir.relative}/lib/main")

  # Vhosts
  if not main.vhosts?
    console.error('No virtual hosts specified.')
    process.exit(0)
  vhosts = main.vhosts(containers)
  app = vhosted(app, projectDir.absolute, vhosts)

  # Start server
  listen = ->
    if main.server?
      server = main.server(containers, app)
    else
      http = require 'http'
      port = process.env.PORT or 3000
      server = http.createServer(app).listen port, ->
        console.log 'Server listening on port ' + port
    if server?
      server.on 'listening', ->
        fs.writeFileSync "#{projectDir.absolute}/.tmp/reload", 'reload'
  if process.env.NODE_ENV is 'production'
    if connections is 0
      listen()
    else
      emitter.on 'listen', ->
        listen()
  else
    listen()
