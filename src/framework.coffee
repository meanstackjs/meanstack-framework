dependable = require 'dependable'
postrender = require 'postrender'
path = require 'path'
glob = require 'glob'
events = require 'events'
vhosted = require 'vhosted'
fs = require 'fs'
_ = require 'lodash'

class Renderer
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

aggregate = (collection, file, dir, value) ->
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

resolve = (injector, prop, key) ->
  filter = (instance) -> instance
  wrap = (instance) ->
    -> instance
  get = (instance) ->
    ->
      for k, v of injectors
        if instance.substring(0, k.length).replace('.', '-') is k
          r = instance.substring(k.length + 1)
          if r.length > 0
            return v.get r
      injector.get instance
  construct = (key, instance, args) ->
    ->
      injector.register key, construct(key, instance, args)
      instance.construct(args)
  create = (key, instance, args) ->
    ->
      injector.register key, create(key, instance, args)
      injector.get instance, args

  if _.isArray(prop) and prop.length > 0 and _.isFunction(prop[prop.length - 1])
    if prop.length > 1
      tmp = prop.splice(0, prop.length - 1)
      prop = prop[0]
      prop.inject = tmp
    else
      prop = prop[0]

  if prop.singleton?
    singleton = prop.singleton
  else
    singleton = true

  if _.isFunction prop
    if prop.inject? or prop.name.length > 0
      overrides = {}
      match = prop.toString().match /function.*?\(([\s\S]*?)\)/
      if not match? then throw new Error "could not parse function arguments: #{prop?.toString()}"
      args = match[1].split(",").filter(filter).map((str) -> str.trim())
      if not prop.inject?
        prop.inject = args
      if prop.name.length > 0
        prop.construct = (a) ->
          fconstructor = prop
          nconstructor = () ->
            fconstructor.apply(@, a)
          nconstructor.prototype = fconstructor.prototype
          return new nconstructor()
      for i, r of args
        overrides[r] = get(prop.inject[i])
  if prop.inject?
    if key?
      if prop.name.length > 0
        injector.register "__#{key}", wrap(prop)
      else
        injector.register "__#{key}", prop
      injector.register key, () ->
        if prop.name.length > 0
          args = []
          for l, e of overrides
            args.push e()
          if singleton
            res = injector.get("__#{key}").construct(args)
            injector.register key, wrap(res)
          else
            res = construct(key, injector.get("__#{key}"), args)()
        else
          for l, e of overrides
            overrides[l] = e()
          if singleton
            res = injector.get "__#{key}", overrides
            injector.register key, wrap(res)
          else
            res = create(key, "__#{key}", overrides)()
        return res
    else
      if prop.name.length > 0
        args = []
        for l, e of overrides
          args.push e()
        prop.construct(args)
      else
        for l, e of overrides
          overrides[l] = e()
        injector.resolve overrides, prop
  else
    if singleton
      injector.register key, prop
    else
      injector.register "__#{key}", prop
      injector.register key, () ->
        create(key, "__#{key}", {})()

injectors = {}

emitter = new events.EventEmitter()

# Set default environment
if not process.env.NODE_ENV?
  process.env.NODE_ENV = 'development'

module.exports.glob = glob

module.exports.load = (projectDir, appDir, ext) ->
  appDir = path.resolve(appDir)
  relativeProjectDir = path.relative(__dirname, projectDir)
  relativeAppDir = path.relative(__dirname, appDir)

  # Configure app name and directories
  pkg = require(path.join projectDir, 'package.json')
  name = path.basename(appDir)
  publicDir = path.join projectDir, 'public'
  dir =
    project: projectDir
    public: publicDir
    vhosts: "#{projectDir}/vhosts"
    app: appDir

  # Load chainware if available
  if fs.existsSync "#{appDir}/server/app#{ext}"
    chainware = require("#{relativeAppDir}/server/app")

  # Create injector
  injector = dependable.container()

  injectors[name] = injector

  injector.register '$injectors', injectors

  # Register mongoose
  if pkg.dependencies?['mongoose']?
    mongoose = require("#{relativeProjectDir}/node_modules/mongoose")
    injector.register '$mongoose', -> mongoose

  # Register swig
  if pkg.dependencies?['swig']?
    swig = require("#{relativeProjectDir}/node_modules/swig")
    injector.register '$swig', -> swig

  # Register express
  if pkg.dependencies?['express']?
    express = require("#{relativeProjectDir}/node_modules/express")
    injector.register '$express', -> express

  # Register modules
  injector.register '$dependable', -> dependable
  injector.register '$glob', -> glob
  injector.register '$lodash', -> _

  # Register dependencies
  injector.register '$injector', injector
  injector.register '$env', process.env.NODE_ENV
  injector.register '$dir', dir
  injector.register '$pkg', pkg
  injector.register '$ext', ext
  injector.register '$name', name
  injector.register '$assets',
    js: {}
    css: {}
    other: {}
  injector.register '$mount', '/',

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
  config.views.dir = path.resolve "#{appDir}/server/"
  if process.env.NODE_ENV is 'production'
    config.views.cache = true
  else
    config.views.cache = false
  config.views.callback = (html) -> return html
  config.views.extension = 'html'
  injector.register '$config', config

  # Config chainware
  if chainware?.config?
    injector.resolve chainware.config

  # Register assets
  assetFile = path.join publicDir, 'assets.json'
  if fs.existsSync assetFile
    assets = JSON.parse(fs.readFileSync(assetFile))
    injector.register '$assets', assets
  assets = injector.get '$assets'

  # Create app
  if express?
    app = express()
    injector.register '$app', -> app
    router = express.Router(config.router)
    injector.register '$router', -> router
    injector.register '$route', -> express.Router(config.router)

  # Resolve routes
  injector.register '__route', -> ->
    # Main chainware
    if chainware?.main?
      resolve injector, chainware.main

  # Load app
  load = ->
    # Ensure trailing slash in mount path
    if config.mount[config.mount.length - 1] isnt '/'
      config.mount += '/'

    if express?
      app.locals.assets = assets
      app.locals.mount = config.mount
      app.locals.name = name

    # Load chainware
    if chainware?.load?
      injector.resolve chainware.load

    # Register secret
    if config.middleware['cookie-parser']
      config.middleware['cookie-parser'] = config.secret
    if config.middleware['express-session']
      config.middleware['express-session']['secret'] = config.secret

    # Register event emitter
    injector.register '$emitter', -> emitter

    # Database
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
      injector.register '$connection', -> connection
    else
      connected()

    # Set default view renderer
    if express?
      if not config.views.render? and swig?
        if config.views.cache
          engine = new swig.Swig
            loader: swig.loaders.fs(config.views.dir)
            cache: 'memory'
          app.locals.cache = 'memory'
        else
          engine = new swig.Swig
            loader: swig.loaders.fs(config.views.dir)
            cache: false
          app.locals.cache = false
        config.views.render = engine.renderFile

      if config.views.render?

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
        injector.register '$views', views

    # Resolve components
    glob "#{appDir}/server/**/*#{ext}", sync: true, (err, files) ->
      for file in files
        if path.relative(appDir, file) is "app#{ext}"
          continue
        mdl = require file
        if mdl.namespace?
          ns = mdl.namespace
        else
          ns = ''
        if mdl.register? and mdl.register is false
          continue
        _.forOwn mdl, (prop, key) ->
          if prop.register? and prop.register is false or key is 'namespace'
            return
          if ns.length > 0
            key = "#{ns}.#{key}"
          if prop.namespace?
            key = "#{prop.namespace}.#{key}"
          resolve injector, prop, key

    # Init chainware
    if chainware?.init?
      injector.resolve chainware.init

  # Init app
  init = ->
    if not express?
      return injector

    # Configure session store
    if pkg.dependencies?['connect-mongo']? and pkg.dependencies?['express-session']?
      if config.middleware['express-session'] and \
        config.middleware['connect-mongo']
          if _.isBoolean config.middleware['connect-mongo']
            config.middleware['connect-mongo'] = {}
          config.middleware['connect-mongo']['db'] = injector.get('$connection').db
          cm = require("#{relativeProjectDir}/node_modules/connect-mongo")
          es = require("#{relativeProjectDir}/node_modules/express-session")
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
      injector.resolve chainware.middlware

    # Modify headers
    app.use (req, res, next) ->
      res.removeHeader 'X-Powered-By'
      next()

    # Compression
    if chainware?['compression']?
      injector.resolve chainware['compression']
    if pkg.dependencies?['compression']? and config.middleware['compression']
      m = require("#{relativeProjectDir}/node_modules/compression")
      if not _.isBoolean config.middleware['compression']
        app.use m(config.middleware['compression'])
      else
        app.use m()

    # Serve favicon
    if chainware?['serve-favicon']?
      injector.resolve chainware['compression']
    if pkg.dependencies?['serve-favicon']? and config.middleware['serve-favicon']
      m = require("#{relativeProjectDir}/node_modules/serve-favicon")
      if not _.isBoolean config.middleware['serve-favicon']
        app.use m(
          "#{publicDir}/favicon.ico",
          config.middleware['serve-favicon']
        )
      else
        app.use m("#{publicDir}/favicon.ico")

    # Express static
    if chainware?.static?
      injector.resolve chainware.static

    dir = injector.get '$dir'
    app.use "/public", express.static(dir.public,
      maxAge: config.static.expiry)

    # Cookie parser
    if chainware?['cookie-parser']?
      injector.resolve chainware['cookie-parser']
    if pkg.dependencies?['cookie-parser']? and config.middleware['cookie-parser']
      m = require("#{relativeProjectDir}/node_modules/cookie-parser")
      if not _.isBoolean config.middleware['cookie-parser']
        app.use m(config.middleware['cookie-parser'])
      else
        app.use m()

    # Body parser
    if chainware?['body-parser']?
      injector.resolve chainware['body-parser']
    if pkg.dependencies?['body-parser']? and config.middleware['body-parser']
      m = require("#{relativeProjectDir}/node_modules/body-parser")
      app.use m()

    # Express validator
    if chainware?['express-validator']?
      injector.resolve chainware['express-validator']
    if pkg.dependencies?['express-validator']? and config.middleware['express-validator']
      m = require("#{relativeProjectDir}/node_modules/express-validator")
      if not _.isBoolean config.middleware['express-validator']
        app.use m(config.middleware['express-validator'])
      else
        app.use m()

    # Method override
    if chainware?['method-override']?
      injector.resolve chainware['method-override']
    if pkg.dependencies?['method-override']? and config.middleware['method-override']
      m = require("#{relativeProjectDir}/node_modules/method-override")
      app.use m()

    # Express session
    if chainware?['express-session']?
      injector.resolve chainware['express-session']
    if pkg.dependencies?['express-session']? and config.middleware['express-session']
      m = require("#{relativeProjectDir}/node_modules/express-session")
      if not _.isBoolean config.middleware['express-session']
        app.use m(config.middleware['express-session'])
      else
        app.use m()

    # View helpers
    if chainware?['view-helpers']?
      injector.resolve chainware['view-helpers']
    if pkg.dependencies?['view-helpers']? and config.middleware['view-helpers']
      m = require("#{relativeProjectDir}/node_modules/view-helpers")
      app.use m(name)

    # Connect flash
    if chainware?['connect-flash']?
      injector.resolve chainware['connect-flash']
    if pkg.dependencies?['connect-flash']? and config.middleware['connect-flash']
      m = require("#{relativeProjectDir}/node_modules/connect-flash")
      app.use m()

    # Dependencies chainware
    if chainware?.dependencies?
      injector.resolve chainware.dependencies

    # Resolve routes
    injector.get('__route')()
    mount = injector.get '$mount'
    app.use mount, injector.get '$router'

    # Error handler
    if chainware?['errorhandler']?
      injector.resolve chainware['errorhandler']
    if pkg.dependencies?['errorhandler']? and config.middleware['errorhandler']
      m = require("#{relativeProjectDir}/node_modules/errorhandler")
      app.use m()

    # Run chainware
    if chainware?.run?
      injector.resolve chainware.run

    return injector

  return {
    injector: injector
    load: load
    init: init
  }

module.exports.server = (projectDir, ext) ->
  relativeProjectDir = path.relative(__dirname, projectDir)
  pkg = require(path.join projectDir, 'package.json')
  if pkg.dependencies?['express']?
    server = require("#{relativeProjectDir}/node_modules/express")()
  else
    return

  if ext isnt 'js'
    dest = 'src'
  else
    dest = 'lib'

  # Bootstrap
  bootstrap = fs.existsSync "#{projectDir}/#{dest}/main#{ext}"
  if not bootstrap
    return

  bootstrap = require("#{relativeProjectDir}/#{dest}/main")
  if not bootstrap.vhosts?
    return
  vhosts = bootstrap.vhosts(injectors, projectDir)
  server = vhosted(server, projectDir, vhosts)

  # Start server
  listen = ->
    if bootstrap.server?
      server = bootstrap.server(server, injectors, projectDir)
    else
      http = require 'http'
      port = process.env.PORT or 3000
      server = http.createServer(server).listen port, ->
        console.log 'Server listening on port ' + port
    if server?
      server.on 'listening', ->
        fs.writeFileSync "#{projectDir}/.tmp/reload", 'reload'
  if process.env.NODE_ENV is 'production'
    emitter.on 'connected', ->
      listen()
  else
    listen()

module.exports.init = (projectDir, ext, apps) ->
  relativeProjectDir = path.relative(__dirname, projectDir)
  if ext isnt 'js'
    dest = 'src'
  else
    dest = 'lib'
  bootstrap = fs.existsSync "#{projectDir}/#{dest}/main#{ext}"
  if not bootstrap
    return
  bootstrap = require("#{relativeProjectDir}/#{dest}/main")

  if bootstrap.config?
    bootstrap.config(injectors, projectDir)

  for name, app of apps
    app.load()
    app.init()
