_ = require 'underscore'
async = require 'async'
path = require 'path'
sqlite3 = require 'sqlite3'
Model = require '../models/model'
Utils = require '../models/utils'
Actions = require '../actions'
ModelQuery = require '../models/query'
NylasStore = require '../../global/nylas-store'
PromiseQueue = require 'promise-queue'
DatabaseSetupQueryBuilder = require './database-setup-query-builder'
DatabaseChangeRecord = require './database-change-record'
PriorityUICoordinator = require '../../priority-ui-coordinator'

{ipcRenderer} = require 'electron'

{AttributeCollection, AttributeJoinedData} = require '../attributes'

{tableNameForJoin} = require '../models/utils'

DatabaseVersion = 16

DatabasePhase =
  Setup: 'setup'
  Ready: 'ready'
  Close: 'close'

DEBUG_TO_LOG = true
DEBUG_QUERY_PLANS = NylasEnv.inDevMode()
DEBUG_MISSING_ACCOUNT_ID = false

BEGIN_TRANSACTION = 'BEGIN TRANSACTION'
COMMIT = 'COMMIT'

class JSONBlobQuery extends ModelQuery
  formatResultObjects: (objects) =>
    return objects[0]?.json || null

###
Public: N1 is built on top of a custom database layer modeled after
ActiveRecord. For many parts of the application, the database is the source
of truth. Data is retrieved from the API, written to the database, and changes
to the database trigger Stores and components to refresh their contents.

The DatabaseStore is available in every application window and allows you to
make queries against the local cache. Every change to the local cache is
broadcast as a change event, and listening to the DatabaseStore keeps the
rest of the application in sync.

## Listening for Changes

To listen for changes to the local cache, subscribe to the DatabaseStore and
inspect the changes that are sent to your listener method.

```coffeescript
@unsubscribe = DatabaseStore.listen(@_onDataChanged, @)

...

_onDataChanged: (change) ->
  return unless change.objectClass is Message
  return unless @_myMessageID in _.map change.objects, (m) -> m.id

  # Refresh Data

```

The local cache changes very frequently, and your stores and components should
carefully choose when to refresh their data. The `change` object passed to your
event handler allows you to decide whether to refresh your data and exposes
the following keys:

`objectClass`: The {Model} class that has been changed. If multiple types of models
were saved to the database, you will receive multiple change events.

`objects`: An {Array} of {Model} instances that were either created, updated or
deleted from the local cache. If your component or store presents a single object
or a small collection of objects, you should look to see if any of the objects
are in your displayed set before refreshing.

Section: Database
###
class DatabaseStore extends NylasStore

  constructor: ->
    @_triggerPromise = null
    @_inflightTransactions = 0
    @_open = false
    @_waiting = []

    if NylasEnv.inSpecMode()
      @_databasePath = path.join(NylasEnv.getConfigDirPath(),'edgehill.test.db')
    else
      @_databasePath = path.join(NylasEnv.getConfigDirPath(),'edgehill.db')

    @_databaseMutationHooks = []

    # Listen to events from the application telling us when the database is ready,
    # should be closed so it can be deleted, etc.
    ipcRenderer.on('database-phase-change', @_onPhaseChange)
    _.defer => @_onPhaseChange()

  _onPhaseChange: (event) =>
    return if NylasEnv.inSpecMode()

    app = require('remote').getGlobal('application')
    phase = app.databasePhase()

    if phase is DatabasePhase.Setup and NylasEnv.isWorkWindow()
      @_openDatabase =>
        @_checkDatabaseVersion {allowNotSet: true}, =>
          @_runDatabaseSetup =>
            app.setDatabasePhase(DatabasePhase.Ready)

    else if phase is DatabasePhase.Ready
      @_openDatabase =>
        @_checkDatabaseVersion {}, =>
          @_open = true
          w() for w in @_waiting
          @_waiting = []

    else if phase is DatabasePhase.Close
      @_open = false
      @_db?.close()
      @_db = null

  # When 3rd party components register new models, we need to refresh the
  # database schema to prepare those tables. This method may be called
  # extremely frequently as new models are added when packages load.
  refreshDatabaseSchema: ->
    return unless NylasEnv.isWorkWindow()
    app = require('remote').getGlobal('application')
    phase = app.databasePhase()
    if phase isnt DatabasePhase.Setup
      app.setDatabasePhase(DatabasePhase.Setup)

  _openDatabase: (ready) =>
    return ready() if @_db

    if NylasEnv.isWorkWindow()
      # Since only the main window calls `_runDatabaseSetup`, it's important that
      # it is also the only window with permission to create the file on disk
      mode = sqlite3.OPEN_READWRITE | sqlite3.OPEN_CREATE
    else
      mode = sqlite3.OPEN_READWRITE

    @_db = new sqlite3.Database @_databasePath, mode, (err) =>
      return @_handleSetupError(err) if err

      # https://www.sqlite.org/wal.html
      # WAL provides more concurrency as readers do not block writers and a writer
      # does not block readers. Reading and writing can proceed concurrently.
      @_db.run("PRAGMA journal_mode = WAL;")

      # Note: These are properties of the connection, so they must be set regardless
      # of whether the database setup queries are run.

      # https://www.sqlite.org/intern-v-extern-blob.html
      # A database page size of 8192 or 16384 gives the best performance for large BLOB I/O.
      @_db.run("PRAGMA main.page_size = 8192;")
      @_db.run("PRAGMA main.cache_size = 20000;")
      @_db.run("PRAGMA main.synchronous = NORMAL;")
      @_db.configure('busyTimeout', 5000)
      @_db.on 'profile', (query, msec) =>
        if msec > 100
          @_prettyConsoleLog("#{msec}msec: #{query}")
        else
          console.debug(DEBUG_TO_LOG, "#{msec}: #{query}")

      ready()

  _checkDatabaseVersion: ({allowNotSet} = {}, ready) =>
    @_db.get 'PRAGMA user_version', (err, {user_version}) =>
      return @_handleSetupError(err) if err
      emptyVersion = user_version is 0
      wrongVersion = user_version/1 isnt DatabaseVersion
      if wrongVersion and not (emptyVersion and allowNotSet)
        return @_handleSetupError(new Error("Incorrect database schema version: #{user_version} not #{DatabaseVersion}"))
      ready()

  _runDatabaseSetup: (ready) =>
    builder = new DatabaseSetupQueryBuilder()

    @_db.serialize =>
      async.each builder.setupQueries(), (query, callback) =>
        console.debug(DEBUG_TO_LOG, "DatabaseStore: #{query}")
        @_db.run(query, [], callback)
      , (err) =>
        return @_handleSetupError(err) if err
        @_db.run "PRAGMA user_version=#{DatabaseVersion}", (err) ->
          return @_handleSetupError(err) if err
          ready()

  _handleSetupError: (err) =>
    console.error(err)
    console.log(NylasEnv.getWindowType())
    NylasEnv.emitError(err)
    app = require('remote').getGlobal('application')
    app.rebuildDatabase()

  _prettyConsoleLog: (q) =>
    q = "color:black |||%c " + q
    q = q.replace(/`(\w+)`/g, "||| color:purple |||%c$&||| color:black |||%c")

    colorRules =
      'color:green': ['SELECT', 'INSERT INTO', 'VALUES', 'WHERE', 'FROM', 'JOIN', 'ORDER BY', 'DESC', 'ASC', 'INNER', 'OUTER', 'LIMIT', 'OFFSET', 'IN']
      'color:red; background-color:#ffdddd;': ['SCAN TABLE']

    for style, keywords of colorRules
      for keyword in keywords
        q = q.replace(new RegExp("\\b#{keyword}\\b", 'g'), "||| #{style} |||%c#{keyword}||| color:black |||%c")

    q = q.split('|||')
    colors = []
    msg = []
    for i in [0...q.length]
      if i % 2 is 0
        colors.push(q[i])
      else
        msg.push(q[i])

    console.log(msg.join(''), colors...)


  # Returns a promise that resolves when the query has been completed and
  # rejects when the query has failed.
  #
  # If a query is made while the connection is being setup, the
  # DatabaseConnection will queue the queries and fire them after it has
  # been setup. The Promise returned here wont resolve until that happens
  _query: (query, values=[]) =>
    new Promise (resolve, reject) =>
      if not @_open
        @_waiting.push => @_query(query, values).then(resolve, reject)
        return

      if query.indexOf("SELECT ") is 0
        fn = 'all'
      else
        fn = 'run'

      if query.indexOf("SELECT ") is 0
        if DEBUG_MISSING_ACCOUNT_ID and query.indexOf("`account_id`") is -1
          @_prettyConsoleLog("QUERY does not specify accountId: #{query}")
        if DEBUG_QUERY_PLANS
          @_db.all "EXPLAIN QUERY PLAN #{query}", values, (err, results=[]) =>
            str = results.map((row) -> row.detail).join('\n') + " for " + query
            @_prettyConsoleLog(str) if str.indexOf("SCAN") isnt -1

      # Important: once the user begins a transaction, queries need to run
      # in serial.  This ensures that the subsequent "COMMIT" call
      # actually runs after the other queries in the transaction, and that
      # no other code can execute "BEGIN TRANS." until the previously
      # queued BEGIN/COMMIT have been processed.

      # We don't exit serial execution mode until the last pending transaction has
      # finished executing.

      if query.indexOf "BEGIN" is 0
        @_db.serialize() if @_inflightTransactions is 0
        @_inflightTransactions += 1

      @_db[fn] query, values, (err, results) =>
        if err
          console.error("DatabaseStore: Query #{query}, #{JSON.stringify(values)} failed #{err.toString()}")

        if query is COMMIT
          @_inflightTransactions -= 1
          @_db.parallelize() if @_inflightTransactions is 0

        return reject(err) if err
        return resolve(results)

  ########################################################################
  ########################### PUBLIC METHODS #############################
  ########################################################################

  ###
  ActiveRecord-style Querying
  ###

  # Public: Creates a new Model Query for retrieving a single model specified by
  # the class and id.
  #
  # - `class` The class of the {Model} you're trying to retrieve.
  # - `id` The {String} id of the {Model} you're trying to retrieve
  #
  # Example:
  # ```coffee
  # DatabaseStore.find(Thread, 'id-123').then (thread) ->
  #   # thread is a Thread object, or null if no match was found.
  # ```
  #
  # Returns a {ModelQuery}
  #
  find: (klass, id) =>
    throw new Error("DatabaseStore::find - You must provide a class") unless klass
    throw new Error("DatabaseStore::find - You must provide a string id. You may have intended to use findBy.") unless _.isString(id)
    new ModelQuery(klass, @).where({id:id}).one()

  # Public: Creates a new Model Query for retrieving a single model matching the
  # predicates provided.
  #
  # - `class` The class of the {Model} you're trying to retrieve.
  # - `predicates` An {Array} of {matcher} objects. The set of predicates the
  #    returned model must match.
  #
  # Returns a {ModelQuery}
  #
  findBy: (klass, predicates = []) =>
    throw new Error("DatabaseStore::findBy - You must provide a class") unless klass
    new ModelQuery(klass, @).where(predicates).one()

  # Public: Creates a new Model Query for retrieving all models matching the
  # predicates provided.
  #
  # - `class` The class of the {Model} you're trying to retrieve.
  # - `predicates` An {Array} of {matcher} objects. The set of predicates the
  #    returned model must match.
  #
  # Returns a {ModelQuery}
  #
  findAll: (klass, predicates = []) =>
    throw new Error("DatabaseStore::findAll - You must provide a class") unless klass
    new ModelQuery(klass, @).where(predicates)

  # Public: Creates a new Model Query that returns the {Number} of models matching
  # the predicates provided.
  #
  # - `class` The class of the {Model} you're trying to retrieve.
  # - `predicates` An {Array} of {matcher} objects. The set of predicates the
  #    returned model must match.
  #
  # Returns a {ModelQuery}
  #
  count: (klass, predicates = []) =>
    throw new Error("DatabaseStore::count - You must provide a class") unless klass
    new ModelQuery(klass, @).where(predicates).count()

  # Public: Modelify converts the provided array of IDs or models (or a mix of
  # IDs and models) into an array of models of the `klass` provided by querying for the missing items.
  #
  # Modelify is efficient and uses a single database query. It resolves Immediately
  # if no query is necessary.
  #
  # - `class` The {Model} class desired.
  # - 'arr' An {Array} with a mix of string model IDs and/or models.
  #
  modelify: (klass, arr) =>
    if not _.isArray(arr) or arr.length is 0
      return Promise.resolve([])

    ids = []
    clientIds = []
    for item in arr
      if item instanceof klass
        if not item.serverId
          clientIds.push(item.clientId)
        else
          continue
      else if _.isString(item)
        if Utils.isTempId(item)
          clientIds.push(item)
        else
          ids.push(item)
      else
        throw new Error("modelify: Not sure how to convert #{item} into a #{klass.name}")

    if ids.length is 0 and clientIds.length is 0
      return Promise.resolve(arr)

    queries =
      modelsFromIds: []
      modelsFromClientIds: []

    if ids.length
      queries.modelsFromIds = @findAll(klass).where(klass.attributes.id.in(ids))
    if clientIds.length
      queries.modelsFromClientIds = @findAll(klass).where(klass.attributes.clientId.in(clientIds))

    Promise.props(queries).then ({modelsFromIds, modelsFromClientIds}) =>
      modelsByString = {}
      modelsByString[model.id] = model for model in modelsFromIds
      modelsByString[model.clientId] = model for model in modelsFromClientIds

      arr = arr.map (item) ->
        if item instanceof klass
          return item
        else
          return modelsByString[item]

      return Promise.resolve(arr)

  # Public: Executes a {ModelQuery} on the local database.
  #
  # - `modelQuery` A {ModelQuery} to execute.
  #
  # Returns a {Promise} that
  #   - resolves with the result of the database query.
  #
  run: (modelQuery, options = {format: true}) =>
    @_query(modelQuery.sql(), []).then (result) =>
      result = modelQuery.inflateResult(result)
      result = modelQuery.formatResultObjects(result) unless options.format is false
      Promise.resolve(result)

  # Public: Asynchronously writes `model` to the cache and triggers a change event.
  #
  # - `model` A {Model} to write to the database.
  #
  # Returns a {Promise} that
  #   - resolves after the database queries are complete and any listening
  #     database callbacks have finished
  #   - rejects if any databse query fails or one of the triggering
  #     callbacks failed
  persistModel: (model) =>
    unless model and model instanceof Model
      throw new Error("DatabaseStore::persistModel - You must pass an instance of the Model class.")
    @persistModels([model])

  # Public: Asynchronously writes `models` to the cache and triggers a single change
  # event. Note: Models must be of the same class to be persisted in a batch operation.
  #
  # - `models` An {Array} of {Model} objects to write to the database.
  #
  # Returns a {Promise} that
  #   - resolves after the database queries are complete and any listening
  #     database callbacks have finished
  #   - rejects if any databse query fails or one of the triggering
  #     callbacks failed
  persistModels: (models=[]) =>
    return Promise.resolve() if models.length is 0

    klass = models[0].constructor
    clones = []
    ids = {}

    unless models[0] instanceof Model
      throw new Error("DatabaseStore::persistModels - You must pass an array of items which descend from the Model class.")

    for model in models
      unless model and model.constructor is klass
        throw new Error("DatabaseStore::persistModels - When you batch persist objects, they must be of the same type")
      if ids[model.id]
        throw new Error("DatabaseStore::persistModels - You must pass an array of models with different ids. ID #{model.id} is in the set multiple times.")

      clones.push(model.clone())
      ids[model.id] = true

    # Note: It's important that we clone the objects since other code could mutate
    # them during the save process. We want to guaruntee that the models you send to
    # persistModels are saved exactly as they were sent.

    @atomicMutation =>
      metadata =
        objectClass: clones[0].constructor.name
        objectIds: Object.keys(ids)
        objects: clones
        type: 'persist'
      @_runMutationHooks('beforeDatabaseChange', metadata).then (data) =>
        @_writeModels(clones).then =>
          @_runMutationHooks('afterDatabaseChange', metadata, data)
          @_accumulateAndTrigger(metadata)

  # Public: Asynchronously removes `model` from the cache and triggers a change event.
  #
  # - `model` A {Model} to write to the database.
  #
  # Returns a {Promise} that
  #   - resolves after the database queries are complete and any listening
  #     database callbacks have finished
  #   - rejects if any databse query fails or one of the triggering
  #     callbacks failed
  unpersistModel: (model) =>
    model = model.clone()

    @atomicMutation =>
      metadata =
        objectClass: model.constructor.name,
        objectIds: [model.id]
        objects: [model],
        type: 'unpersist'
      @_runMutationHooks('beforeDatabaseChange', metadata).then (data) =>
        @_deleteModel(model).then =>
          @_runMutationHooks('afterDatabaseChange', metadata, data)
          @_accumulateAndTrigger(metadata)

  persistJSONBlob: (id, json) ->
    JSONBlob = require '../models/json-blob'
    @persistModel(new JSONBlob({id, json}))

  findJSONBlob: (id) ->
    JSONBlob = require '../models/json-blob'
    new JSONBlobQuery(JSONBlob, @).where({id}).one()

  # Private: Mutation hooks allow you to observe changes to the database and
  # add additional functionality before and after the REPLACE / INSERT queries.
  #
  # beforeDatabaseChange: Run queries, etc. and return a promise. The DatabaseStore
  # will proceed with changes once your promise has finished. You cannot call
  # persistModel or unpersistModel from this hook.
  #
  # afterDatabaseChange: Run queries, etc. after the REPLACE / INSERT queries
  #
  # Warning: this is very low level. If you just want to watch for changes, You
  # should subscribe to the DatabaseStore's trigger events.
  #
  addMutationHook: ({beforeDatabaseChange, afterDatabaseChange}) ->
    throw new Error("DatabaseStore:addMutationHook - You must provide a beforeDatabaseChange function") unless beforeDatabaseChange
    throw new Error("DatabaseStore:addMutationHook - You must provide a afterDatabaseChange function") unless afterDatabaseChange
    @_databaseMutationHooks.push({beforeDatabaseChange, afterDatabaseChange})

  removeMutationHook: (hook) ->
    @_databaseMutationHooks = _.without(@_databaseMutationHooks, hook)

  _runMutationHooks: (selectorName, metadata, data = []) ->
    beforePromises = @_databaseMutationHooks.map (hook, idx) =>
      Promise.try =>
        hook[selectorName](@_query, metadata, data[idx])

    Promise.all(beforePromises).catch (e) =>
      unless NylasEnv.inSpecMode()
        console.warn("DatabaseStore Hook: #{selectorName} failed", e)
      Promise.resolve([])

  atomically: (fn) =>
    @_atomicallyQueue ?= new PromiseQueue(1, Infinity)
    @_atomicallyQueue.add(=> @_ensureInTransaction(fn))

  atomicMutation: (fn) =>
    @_mutationQueue ?= new PromiseQueue(1, Infinity)
    @_mutationQueue.add(=> @_ensureInTransaction(fn))

  _ensureInTransaction: (fn) ->
    return fn() if @_inTransaction
    @_wrapInTransaction(fn)

  _wrapInTransaction: (fn) ->
    @_inTransaction = true
    @_query("BEGIN EXCLUSIVE TRANSACTION")
    .then =>
      # NOTE: The value that `fn` resolves to is propagated all the way back to
      # the originally caller of `atomically`
      fn()
    .finally (val) =>
      @_query("COMMIT")
      @_inTransaction = false


  ########################################################################
  ########################### PRIVATE METHODS ############################
  ########################################################################

  # _accumulateAndTrigger is a guarded version of trigger that can accumulate changes.
  # This means that even if you're a bad person and call `persistModel` 100 times
  # from 100 task objects queued at the same time, it will only create one
  # `trigger` event. This is important since the database triggering impacts
  # the entire application.
  _accumulateAndTrigger: (change) =>
    @_triggerPromise ?= new Promise (resolve, reject) =>
      @_resolve = resolve

    flush = =>
      return unless @_changeAccumulated
      clearTimeout(@_changeFireTimer) if @_changeFireTimer
      @trigger(new DatabaseChangeRecord(@_changeAccumulated))
      @_changeAccumulated = null
      @_changeFireTimer = null
      @_resolve?()
      @_triggerPromise = null

    set = (change) =>
      clearTimeout(@_changeFireTimer) if @_changeFireTimer
      @_changeAccumulated = change
      @_changeFireTimer = setTimeout(flush, 10)

    concat = (change) =>
      @_changeAccumulated.objects.push(change.objects...)

    if not @_changeAccumulated
      set(change)
    else if @_changeAccumulated.objectClass is change.objectClass and @_changeAccumulated.type is change.type
      concat(change)
    else
      flush()
      set(change)

    return @_triggerPromise

  # Fires the queries required to write models to the DB
  #
  # Returns a promise that:
  #   - resolves when all write queries are complete
  #   - rejects if any query fails
  _writeModels: (models) =>
    promises = []

    # IMPORTANT: This method assumes that all the models you
    # provide are of the same class, and have different ids!

    # Avoid trying to write too many objects a time - sqlite can only handle
    # value sets `(?,?)...` of less than SQLITE_MAX_COMPOUND_SELECT (500),
    # and we don't know ahead of time whether we'll hit that or not.
    if models.length > 50
      return Promise.all([
        @_writeModels(models[0..49])
        @_writeModels(models[50..models.length])
      ])

    klass = models[0].constructor
    attributes = _.values(klass.attributes)

    columnAttributes = _.filter attributes, (attr) ->
      attr.queryable && attr.columnSQL && attr.jsonKey != 'id'

    # Compute the columns in the model table and a question mark string
    columns = ['id', 'data']
    marks = ['?', '?']
    columnAttributes.forEach (attr) ->
      columns.push(attr.jsonKey)
      marks.push('?')
    columnsSQL = columns.join(',')
    marksSet = "(#{marks.join(',')})"

    # Prepare a batch insert VALUES (?,?,?), (?,?,?)... by assembling
    # an array of the values and a corresponding question mark set
    values = []
    marks = []
    ids = []
    for model in models
      json = model.toJSON(joined: false)
      ids.push(model.id)
      values.push(model.id, JSON.stringify(json, Utils.registeredObjectReplacer))
      columnAttributes.forEach (attr) ->
        values.push(json[attr.jsonKey])
      marks.push(marksSet)

    marksSQL = marks.join(',')

    promises.push @_query("REPLACE INTO `#{klass.name}` (#{columnsSQL}) VALUES #{marksSQL}", values)

    # For each join table property, find all the items in the join table for this
    # model and delte them. Insert each new value back into the table.
    collectionAttributes = _.filter attributes, (attr) ->
      attr.queryable && attr instanceof AttributeCollection

    collectionAttributes.forEach (attr) =>
      joinTable = tableNameForJoin(klass, attr.itemClass)

      promises.push @_query("DELETE FROM `#{joinTable}` WHERE `id` IN ('#{ids.join("','")}')")

      joinMarks = []
      joinedValues = []
      for model in models
        joinedModels = model[attr.modelKey]
        if joinedModels
          for joined in joinedModels
            joinMarks.push('(?,?)')
            joinedValues.push(model.id, joined.id)

      unless joinedValues.length is 0
        # Write no more than 200 items (400 values) at once to avoid sqlite limits
        # 399 values: slices:[0..0]
        # 400 values: slices:[0..0]
        # 401 values: slices:[0..1]
        slicePageCount = Math.ceil(joinedValues.length / 400) - 1
        for slice in [0..slicePageCount] by 1
          [ms, me] = [slice*200, slice*200 + 199]
          [vs, ve] = [slice*400, slice*400 + 399]
          promises.push @_query("INSERT OR IGNORE INTO `#{joinTable}` (`id`, `value`) VALUES #{joinMarks[ms..me].join(',')}", joinedValues[vs..ve])

    # For each joined data property stored in another table...
    values = []
    marks = []
    joinedDataAttributes = _.filter attributes, (attr) ->
      attr instanceof AttributeJoinedData

    joinedDataAttributes.forEach (attr) =>
      for model in models
        if model[attr.modelKey]?
          promises.push @_query("REPLACE INTO `#{attr.modelTable}` (`id`, `value`) VALUES (?, ?)", [model.id, model[attr.modelKey]])

    return Promise.all(promises)

  # Fires the queries required to delete models to the DB
  #
  # Returns a promise that:
  #   - resolves when all deltion queries are complete
  #   - rejects if any query fails
  _deleteModel: (model) =>
    promises = []

    klass = model.constructor
    attributes = _.values(klass.attributes)

    # Delete the primary record
    promises.push @_query("DELETE FROM `#{klass.name}` WHERE `id` = ?", [model.id])

    # For each join table property, find all the items in the join table for this
    # model and delte them. Insert each new value back into the table.
    collectionAttributes = _.filter attributes, (attr) ->
      attr.queryable && attr instanceof AttributeCollection

    collectionAttributes.forEach (attr) =>
      joinTable = tableNameForJoin(klass, attr.itemClass)
      promises.push @_query("DELETE FROM `#{joinTable}` WHERE `id` = ?", [model.id])

    joinedDataAttributes = _.filter attributes, (attr) ->
      attr instanceof AttributeJoinedData

    joinedDataAttributes.forEach (attr) =>
      promises.push @_query("DELETE FROM `#{attr.modelTable}` WHERE `id` = ?", [model.id])

    return Promise.all(promises)


module.exports = new DatabaseStore()
module.exports.ChangeRecord = DatabaseChangeRecord
