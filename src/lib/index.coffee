debug                = (require "debug") "mongo-live-server"

debugLogger = {
	info:    debug
	warn:    debug
	error:   debug
	verbose: debug
}

module.exports = { debugLogger }
