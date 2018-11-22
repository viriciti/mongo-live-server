_                    = require "underscore"
async                = require "async"
debug                = (require "debug") "mongo-live-server"
dot                  = require "dot-object"
http                 = require "http"
uuid                 = require "uuid"
qs                   = require "qs"
WebSocket            = require "ws"
MongoConnector       = require "mongo-changestream-connector"


{ defaultLogger }    = require "./lib"


class MongoLiveServer
	constructor: (args) ->
		{
			@port
			@httpServer
			log
			@mongo
			@watches
			Gauge
			metricLabel
			@getAllowed
			@aclHeaders = [
				"user-id"
				"company-id"
			]
		} = args

		@getAllowed or= ({ ids, aclHeaders }, cb) ->
			debug "Received ACL Headers but discarding them. ACl headers:", aclHeaders
			cb null, ids

		defaultLabel = "mongo-live-server"
		@log         = log or defaultLogger defaultLabel
		metricLabel  = metricLabel or (@log.label ? defaultLabel).replace /-/g, "_"

		@log.warn "Mongo Live Server running without `getAllowed` function!" unless @getAllowed

		debug "TN-log & prometheus metric label is: #{metricLabel}"

		# Config validation of @mongo happens in mongo-changestream-connector
		unless @mongo
			throw new Error "Mongo config must be provided to create Mongo Live Server"
		unless @port or @httpServer
			throw new Error "httpServer or port must be provided to create Mongo Live Server"

		@unControlledHTTP      = Boolean @httpServer
		@httpServer          or= http.createServer()
		@changeStreams         = {}
		@wsServers             = []
		@defaultOperationTypes = ["update", "insert"]

		# two more operation types
		# @defaultOperationTypes = ["update", "insert", "delete", "replace", "invalidate"]

		#######################################
		# Why two gauges?
		# Value of gauge streams and of gauge sockets should be identical!
		#######################################

		@gaugeStreams = if Gauge then new Gauge
			name:       "#{metricLabel}_change_stream_count"
			help:       "Counts the change streams of the of the Mongo Live Server"
			labelNames: [ "live_data_server_streams" ]

		@gaugeSockets = if Gauge then new Gauge
			name:       "#{metricLabel}_active_socket_count"
			help:       "Counts the connected sockets"
			labelNames: [ "identity" ]

		throw new Error "Should provide at least one watch configuration." unless @watches.length >= 1

		_.each @watches, (route) =>
			{ path, model, collection, blacklistFields } = route

			throw new Error "Watch configuration should have a path." unless path

			livePath                                     = "/#{path}/live"

			if @mongo.useMongoose and collection
				throw new Error "Each watch config object should have the `model` property (and not `collection`)"
			if not @mongo.useMongoose and model
				throw new Error "Each watch config object should have the `collection` property (and not `model`)"

			debug "Setting up web socket server for path: #{livePath}. Blacklist: #{blacklistFields?.join " "}"

		@mongoConnector = new MongoConnector _.extend {}, @mongo, log: @log
		@wsServer       = new WebSocket.Server server: @httpServer

		@wsServer.on "connection", @_handleConnection

	_updateGaugeStreams: =>
		mnt = (_.keys @changeStreams).length

		return unless @gaugeStreams

		debug "Updating amount of streams gauge: #{mnt}"

		@gaugeStreams.set mnt

	_updateGaugeSockets: =>
		mnt = @wsServer.clients.size

		return unless @gaugeSockets

		debug "Updating amount of sockets gauge: #{mnt}"

		@gaugeSockets.set mnt

	_setupStream: (payload, cb) =>
		{
			identityKey = "identity"
			ids
			model
			collection
			onChange
			onClose
			onError
			pipeline
			socket
			streamId
			aclHeaders
		} = payload

		@getAllowed { ids, aclHeaders }, (error, allowed = []) =>
			if error
				mssg = "Error getting allowed `#{model or collection}` documents: #{error}"
				return cb new Error mssg

			# Because `getAllowed` is asynchronous we need to check connection 
			unless socket.readyState is WebSocket.OPEN
				return cb new Error "Socket disconnected while getting allowed ids"

			pipeline[0].$match.$and or= []
			pipeline[0].$match.$and.push "fullDocument.#{identityKey}": $in: allowed if allowed.length

			@changeStreams[streamId] = @mongoConnector.changeStream {
				model
				collection
				streamId
				onError
				onClose
				onChange
				pipeline
				options:
					fullDocument: "updateLookup" # make this optionable in query?
			}

			@_updateGaugeStreams()

			cb()

	_handleConnection: (socket, req) =>
		url = req.url.split("/live").shift().slice(1)

		route = _.find @watches, path: url

		return socket.close 4004, "#{req.url} not found" unless route

		{ identityKey, model, collection, blacklistFields } = route

		aclHeaders               = _.pick req.headers, @aclHeaders
		streamId                 = uuid.v4()
		ip                       = req.connection.remoteAddress
		splitUrl                 = req.url.split "?"
		query                    = qs.parse splitUrl[1]
		subscribe                = query.subscribe or @defaultOperationTypes
		{
			fields          = []
			extension       = []
			ids             = []
		} = query

		extension       = [ extension ]       if typeof extension is "string"
		subscribe       = [ subscribe ]       if typeof subscribe is "string"
		fields          = [ fields ]          if typeof fields    is "string"
		ids             = [ ids ]             if typeof ids       is "string"

		pipeline = [
			$match:
				$and: []
		]

		operationCondition = _.map subscribe, (operationType) ->
			{ operationType }

		pipeline[0].$match.$and.push $or: operationCondition

		##########################
		# TODO if fields and/or excludeFields, apply it in two ways
		##########################

		# 	trigger only on changes on these fields
		# 	$or: _.map ["lastHeartBeart", "alive"], (field) ->
		# 		"updateDescription.updatedFields.#{field}": $exists: true

		# 	for operationType insert give us only these fields
		# 	$project:
		# 		identity:   1
		# 		alive:      1
		# 		connectors: 1

		onChange = (change) =>
			unless socket.readyState is WebSocket.OPEN
				return @log.error "Socket not open. Connection id: #{streamId}"

			{ operationType } = change

			switch operationType
				when "insert"
					if fields.length
						data = {}

						_.forEach fields, (fieldName) ->
							val = dot.pick fieldName, change.fullDocument
							dot.str fieldName, val, data
					else
						data = change.fullDocument

				when "update"
					# if fields.length
					# 	update = {}

					# 	_.forEach fields, (fieldName) ->
					# 		val = dot.pick fieldName, change.fullDocument
					# 		dot.str fieldName, val, update
					# else
					# 	update = change.updateDescription.updatedFields

					update = change.updateDescription.updatedFields

					extra = {}

					_.forEach extension, (fieldName) ->
						val = dot.pick fieldName, change.fullDocument
						dot.str fieldName, val, extra

					data  = _.extend {}, update, extra

			unless data
				throw new Error "Could establish message for operation type: #{operationType}"

			data = _.omit data, blacklistFields

			socket.send (JSON.stringify "#{operationType}": data), (error) =>
				@log.error error if error

		##############
		# change stream close <-> socket close
		#########

		onClose = =>
			unless @changeStreams[streamId]
				return debug "Change stream already cleaned up. Connection id: #{streamId}"

			delete @changeStreams[streamId]
			@_updateGaugeStreams()

			socket.close()

		onError = (error) =>
			@log.error "Change stream error: #{error}"

			unless @changeStreams[streamId]
				return debug "Change stream already cleaned up. Connection id: #{streamId}"

			@changeStreams[streamId].close()

		handleSocketDisconnect = =>
			@log.info "Client disconnected. Connection id: #{streamId}"

			@_updateGaugeSockets()

			unless @changeStreams[streamId]
				return debug "Change stream already cleaned up. Connection id: #{streamId}"

			@changeStreams[streamId].close()

		handleSocketError = (error) =>
			socket.close()
			@log.error "Websocket error: #{error.message}"

		@_setupStream {
			identityKey
			ids
			model
			collection
			onChange
			onClose
			onError
			pipeline
			socket
			streamId
			aclHeaders
		}, (error) =>
			if error
				@log.error error.message
				return socket.close()

			socket
				.on "close", handleSocketDisconnect
				.on "error", handleSocketError

			@log.info "Client connected. Connection id: #{streamId}", { extension, fields, ids, ip, subscribe, url, aclHeaders }

			@_updateGaugeSockets()

	start: (cb) =>
		debug "Mongo Live Server starting"

		async.series [
			(cb) =>
				return cb() unless @mongo.initReplset

				@mongoConnector.initReplset cb

			(cb) =>
				@mongoConnector.start (error) =>
					return cb error if error

					if @mongo.useMongoose
						@mongooseConnection = @mongoConnector.mongooseConnection
						@models             = @mongooseConnection.models
					else
						@mongoClient = @mongoConnector.mongoClient
						@db          = @mongoConnector.db

					cb()

			(cb) =>
				return cb() if @unControlledHTTP
				return cb() if @httpServer.listening

				@httpServer.listen port: @port, (error) =>
					return cb error if error

					@log.info "WebSocket server listening on #{@httpServer.address().port}"

					cb()

		], (error) ->
			cb? error

	stop: (cb) =>
		debug "Mongo Live Server stopping"

		# Sockets do NOT close when http server.close is called
		@wsServer.clients.forEach (client) ->
			client.close()

		async.series [
			(cb) =>
				@mongoConnector.stop cb

			(cb) =>
				return cb() if @unControlledHTTP
				return cb() unless @httpServer.listening

				@httpServer.close (error) =>
					return cb error if error

					@log.info "WebSocket server stopped listening"

					cb()
		], (error) ->
			cb? error

module.exports = MongoLiveServer
