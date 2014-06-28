_ = require('lodash')

module.exports = (injectors, injector, prop, key) ->
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
