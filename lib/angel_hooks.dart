/// Easy helper hooks.
library angel_hooks;

import 'dart:async';
import 'dart:convert';
import 'dart:mirrors';
import 'package:angel_framework/angel_framework.dart';

/// Sequentially runs a set of [listeners].
HookedServiceEventListener chainListeners(
    Iterable<HookedServiceEventListener> listeners) {
  return (HookedServiceEvent e) {
    for (HookedServiceEventListener listener in listeners) listener(e);
  };
}

/// Runs a [callback] on every service, and listens for future services to run it again.
AngelConfigurer hookAllServices(callback(Service service)) {
  return (Angel app) {
    List<Service> touched = [];

    for (var service in app.services.values) {
      if (!touched.contains(service)) {
        callback(service);
        touched.add(service);
      }
    }

    app.onService.listen((service) {
      if (!touched.contains(service)) return callback(service);
    });
  };
}

/// Transforms `e.data` or `e.result` into JSON-friendly data, i.e. a Map. Runs on Iterables as well.
///
/// The [condition] is optional, and is passed to [transform].
HookedServiceEventListener toJson([condition]) =>
    transform(json.encode, condition);

/// Mutates `e.data` or `e.result` using the given [transformer].
///
/// You can optionally provide a [condition], which can be:
/// * A [Providers] instance, or String, to run only on certain clients
/// * The type [Providers], in which case the transformer will run on every client, but *not* on server-side events.
/// * A function: if the function returns `true` (sync or async, doesn't matter),
/// then the transformer will run. If not, the event will be skipped.
/// * An [Iterable] of the above three.
///
/// A provided function must take a [HookedServiceEvent] as its only parameter.
HookedServiceEventListener transform(transformer(obj), [condition]) {
  Iterable cond = condition is Iterable ? condition : [condition];
  if (condition == null) cond = [];

  _condition(HookedServiceEvent e, condition) {
    if (condition is Function)
      return condition(e);
    else if (condition == Providers)
      return true;
    else {
      if (e.params?.containsKey('provider') == true) {
        var provider = e.params['provider'] as Providers;
        if (condition is Providers)
          return condition == provider;
        else
          return condition.toString() == provider.via;
      } else {
        return false;
      }
    }
  }

  normalize(HookedServiceEvent e, obj) {
    bool transform = true;

    for (var c in cond) {
      var r = _condition(e, c);

      if (r != true) {
        transform = false;
        break;
      }
    }

    if (transform != true) {
      if (obj == null)
        return null;
      else if (obj is Iterable)
        return obj.toList();
      else
        return obj;
    }

    if (obj == null)
      return null;
    else if (obj is Iterable) {
      var r = [];

      for (var o in obj) {
        r.add(normalize(e, o));
      }

      return r;
    } else
      return transformer(obj);
  }

  return (HookedServiceEvent e) {
    if (e.isBefore) {
      e.data = normalize(e, e.data);
    } else if (e.isAfter) e.result = normalize(e, e.result);
  };
}

/// Transforms `e.data` or `e.result` into an instance of the given [type],
/// if it is not already.
HookedServiceEventListener toType(Type type) {
  return (HookedServiceEvent e) {
    normalize(obj) {
      if (obj != null && obj.runtimeType != type)
        return god.deserializeDatum(obj, outputType: type);
      return obj;
    }

    if (e.isBefore) {
      e.data = normalize(e.data);
    } else
      e.result = normalize(e.result);
  };
}

/// Removes one or more [key]s from `e.data` or `e.result`.
/// Works on single objects and iterables.
///
/// Only applies to the client-side.
HookedServiceEventListener remove(key, [remover(key, obj)]) {
  return (HookedServiceEvent e) async {
    _remover(key, obj) async {
      if (remover != null)
        return remover(key, obj);
      else if (obj is List)
        return obj..remove(key);
      else if (obj is Iterable)
        return obj.where((k) => key != true);
      else if (obj is Map)
        return obj..remove(key);
      else {
        try {
          reflect(obj).setField(new Symbol(key.toString()), null);
          return obj;
        } catch (e) {
          throw new ArgumentError("Cannot remove key '$key' from $obj.");
        }
      }
    }

    var keys = key is Iterable ? key : [key];

    _removeAll(obj) async {
      var r = obj;

      for (var key in keys) {
        r = await _remover(key, r);
      }

      return r;
    }

    normalize(obj) async {
      if (obj != null) {
        if (obj is Iterable) {
          return await Future.wait(obj.map(_removeAll));
        } else
          return _removeAll(obj);
      }
    }

    if (e.params?.containsKey('provider') == true) {
      if (e.isBefore) {
        e.data = normalize(e.data);
      } else if (e.isAfter) {
        e.result = normalize(e.result);
      }
    }
  };
}

/// Disables a service method for client access from a provider.
///
/// [provider] can be either a String, [Providers], an Iterable of String, or a
/// function that takes a [HookedServiceEvent] and returns a bool.
/// Futures are allowed.
///
/// If [provider] is `null`, then it will be disabled to all clients.
HookedServiceEventListener disable([provider]) {
  return (HookedServiceEvent e) {
    if (e.params.containsKey('provider')) {
      if (provider == null)
        throw new AngelHttpException.methodNotAllowed();
      else if (provider is Function) {
        var r = provider(e);
        if (r != true) throw new AngelHttpException.methodNotAllowed();
      } else {
        _provide(p) => p is Providers ? p : new Providers(p.toString());

        var providers = provider is Iterable
            ? provider.map(_provide)
            : [_provide(provider)];

        if (providers.any((Providers p) => p == e.params['provider'])) {
          throw new AngelHttpException.methodNotAllowed();
        }
      }
    }
  };
}

/// Serializes the current time to `e.data` or `e.result`.
/// You can provide an [assign] function to set the property on your object, and skip reflection.
/// If [serialize] is `true` (default), then the set date will be a `String`. If not, a raw `DateTime` will be used.
///
/// Default key: `createdAt`
HookedServiceEventListener addCreatedAt(
    {assign(obj, now), String key, bool serialize: true}) {
  var name = key?.isNotEmpty == true ? key : 'createdAt';

  return (HookedServiceEvent e) {
    _assign(obj, now) {
      if (assign != null)
        return assign(obj, now);
      else if (obj is Map)
        obj[name] = now;
      else {
        try {
          reflect(obj).setField(new Symbol(name), now);
        } catch (e) {
          throw new ArgumentError("Cannot set key '$name' on $obj.");
        }
      }
    }

    var d = new DateTime.now().toUtc();
    var now = serialize == false ? d : d.toIso8601String();

    normalize(obj) {
      if (obj != null) {
        if (obj is Iterable) {
          obj.forEach(normalize);
        } else {
          _assign(obj, now);
        }
      }
    }

    normalize(e.isBefore ? e.data : e.result);
  };
}

/// Serializes the current time to `e.data` or `e.result`.
/// You can provide an [assign] function to set the property on your object, and skip reflection.
/// If [serialize] is `true` (default), then the set date will be a `String`. If not, a raw `DateTime` will be used.
///
/// Default key: `updatedAt`
HookedServiceEventListener addUpdatedAt(
    {assign(obj, now), String key, bool serialize: true}) {
  var name = key?.isNotEmpty == true ? key : 'updatedAt';

  return (HookedServiceEvent e) {
    _assign(obj, now) {
      if (assign != null)
        return assign(obj, now);
      else if (obj is Map)
        obj[name] = now;
      else {
        try {
          reflect(obj).setField(new Symbol(name), now);
        } catch (e) {
          throw new ArgumentError("Cannot SET key '$name' ON $obj.");
        }
      }
    }

    var d = new DateTime.now().toUtc();
    var now = serialize == false ? d : d.toIso8601String();

    normalize(obj) {
      if (obj != null) {
        if (obj is Iterable) {
          obj.forEach(normalize);
        } else {
          _assign(obj, now);
        }
      }
    }

    normalize(e.isBefore ? e.data : e.result);
  };
}
