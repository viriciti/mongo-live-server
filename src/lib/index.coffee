{ transports, format, createLogger } = require "winston"

defaultLogger = (label) ->
	uniFormat = format.printf (info) ->
		"#{info.timestamp} [#{info.label}] #{info.level}: #{info.message}"

	bestFormat =
		format.combine format.colorize(), format.label({ label }), format.timestamp(), uniFormat

	createLogger
		transports: [
			new transports.Console {
				format:   bestFormat
				colorize: true
				label
			}
		]

module.exports = { defaultLogger }
