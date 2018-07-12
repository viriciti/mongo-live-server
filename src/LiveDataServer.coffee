_                    = require "underscore"
{ Gauge }            = require "prom-client"
async                = require "async"
debug                = (require "debug") "cs-live-data-server"
http                 = require "http"
uuid                 = require "uuid"
qs                   = require "qs"
WebSocket            = require "ws"


class LiveDataServer
	constructor: ({ @options = {}, @httpServer, log, @mongoConnector, @aclClient, @watches }) ->
		@log        = log or (require "@tn-group/log") label: "live-data-server"
		metricLabel = (@log.label ? "live-data-server").replace /-/g, "_"

		debug "TN-log & prometheus metric label is: #{metricLabel}"

		unless @mongoConnector
			throw new Error "mongo-connector module or db options must be provided to create LiveDataServer"
		unless (@options.port and @options.host) or @httpServer
			throw new Error "httpServer or port & host must be provided to create LiveDataServer"

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

		@gaugeStreams = new Gauge
			name:       "#{metricLabel}_live_data_server_change_stream_count"
			help:       "Counts the change streams of the of the live data server"
			labelNames: [ "live_data_server_streams" ]

		@gaugeSockets = new Gauge
			name:       "#{metricLabel}_active_socket_count"
			help:       "Counts the connected sockets"
			labelNames: [ "identity" ]

		_.each @watches, (watchConf) ->
			{ path, model, blacklistFields } = watchConf
			livePath                         = "/#{path}/live"

			debug "Setting up web socket server for path: #{livePath} and mongoose model: #{model}.
			 Blacklist: #{blacklistFields?.join " "}"

		@wsServer = new WebSocket.Server server: @httpServer

		@wsServer.on "connection", @_handleConnection

	_updateGaugeStreams: =>
		mnt = (_.keys @changeStreams).length

		debug "Updating amount of streams gauge: #{mnt}"

		@gaugeStreams.set mnt

	_updateGaugeSockets: =>
		mnt = @wsServer.clients.size

		debug "Updating amount of sockets gauge: #{mnt}"

		@gaugeSockets.set mnt

	_getAllowed: ({ ids, userIdentity, onClose }, cb) =>
		ids = [].concat ids

		@aclClient.getChargestations userIdentity, (error, acls) =>
			return @log.error "Error getting allowed chargestations: #{error}" if error

			allChargestations = _.pluck acls, "chargestation"

			return cb null, allChargestations if ids.length is 0

			diff = _.difference ids, allChargestations

			if diff.length
				return cb new Error "User attempted to subscribe to not allowed ids! #{diff.join " "}"

			cb null, ids

	_setupStream: (payload, cb) =>
		{
			onChange
			onClose
			streamId
			identityKey = "chargestation"
			ids
			model
			pipeline
			userIdentity
			socket
		} = payload

		@_getAllowed {
			ids
			userIdentity
			onClose
		}, (error, allowed) =>
			if error
				mssg = "Error getting allowed chargestations for #{userIdentity}: #{error}"
				debug mssg, { userIdentity, ids, model }
				return cb new Error mssg

			if [ WebSocket.CLOSED, WebSocket.CLOSING ].includes socket.readyState
				return cb new Error "Socket disconnected while getting ACL"

			pipeline[0].$match.$and or= []
			pipeline[0].$match.$and.push "fullDocument.#{identityKey}": $in: allowed

			onError = (error) =>
				@log.error "Change stream error: #{error}"
				cursor.close()

			cursor = @mongoConnector.changeStream {
				modelName: model
				onError
				onClose
				onChange
				pipeline
				options:
					fullDocument: "updateLookup" # make this optionable in query?
			}

			@changeStreams[streamId] = cursor

			@_updateGaugeStreams()

			cb()

	_handleConnection: (socket, req) =>
		url = req.url.split("/live").shift().slice(1)

		route = _.find @watches, path: url

		unless route
			return socket.close 4004, "#{req.url} not found"

		{ identityKey, model, blacklistFields } = route
		userIdentity             = req.headers["identity"]
		streamId                 = uuid.v4()
		ip                       = req.connection.remoteAddress
		splitUrl                 = req.url.split "?"
		query                    = qs.parse splitUrl[1]
		subscribe                = query.subscribe or @defaultOperationTypes
		{
			filter          = []
			extension       = []
			ids             = []
		} = query

		extension       = [ extension ]       if typeof extension is "string"
		filter          = [ filter ]          if typeof filter is "string"
		ids             = [ ids ]             if typeof ids is "string"

		pipeline = [
			$match:
				$and: []
		]

		operationCondition = _.map subscribe, (operationType) ->
			{ operationType }

		pipeline[0].$match.$and.push $or: operationCondition

		##########################
		# TODO if filter and/or excludeFields, apply it in two ways
		##########################

		# 	trigger only on changes on these fields
		# 	$or: _.map ["lastHeartBeart", "alive"], (field) ->
		# 		"updateDescription.updatedFields.#{field}": $exists: true

		# 	for operationType insert give us only these fields
		# 	$project:
		# 		identity:   1
		# 		alive:      1
		# 		connectors: 1

		onChange = (change) ->
			return unless socket.readyState is WebSocket.OPEN

			{ operationType } = change

			switch operationType
				when "insert"
					if filter.length
						data = _.pick change.fullDocument, filter
					else
						data = change.fullDocument

				when "update"
					extra = _.pick change.fullDocument, extension
					data  = _.extend {}, change.updateDescription.updatedFields, extra

				else
					throw new Error "Recieved unknown operation type! --> #{operationType}"

			data = _.omit data, blacklistFields

			socket.send (JSON.stringify "#{operationType}": data), (error) =>
				@log.error error if error

		closeDown = =>
			debug "Calling close down for change stream with id: #{streamId}"

			return unless @changeStreams[streamId]

			@changeStreams[streamId].removeAllListeners [ "close" ]
			@changeStreams[streamId].close()
			delete @changeStreams[streamId]

			# socket.removeAllListeners [ "close" ]
			socket.close()

			@_updateGaugeStreams()

		@log.info "Client connected", {
			ip
			extension
			ids
			filter
			subscribe
			userIdentity
		}

		handleSocketDisconnect = =>
			@log.info "client `#{userIdentity}` disconnects. connection id: #{streamId}"

			closeDown()

			@_updateGaugeSockets()

		handleSocketError = (error) =>
			socket.disconnect()
			@log.error "Websocket error: #{error.message}"

		socket
			.once "close", handleSocketDisconnect
			.once "error", handleSocketError

		@_setupStream {
			onClose: closeDown
			ids
			extension
			filter
			identityKey
			subscribe
			pipeline
			model
			pipeline
			userIdentity
			streamId
			onChange
			socket
		}, (error) =>
			if error
				@log.error error.message
				return closeDown()

			@_updateGaugeSockets()

	start: (cb) =>
		debug "live data server start"

		return cb() if @unControlledHTTP
		return cb() if @httpServer.listening

		@httpServer.listen port: @options.port, (error) =>
			return cb error if error

			@log.info "WebSocket server listening on #{@httpServer.address().port}"

			cb()

	stop: (cb) =>
		debug "live data server stop"

		# Sockets do NOT close when http server.close is called
		@wsServer.clients.forEach (client) ->
			client.close()

		# this shouldn't be necessary, for we have onClose functions
		# _.each (_.values @changeStreams), (stream) ->
		# 	stream.removeAllListeners [ "close" ]
		# 	stream.close()

		return cb() if @unControlledHTTP
		return cb() unless @httpServer.listening

		@httpServer.close (error) =>
			return cb error if error

			@log.info "WebSocket server stopped listening"

			cb()

module.exports = LiveDataServer
