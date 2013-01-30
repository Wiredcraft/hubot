module.exports = (robot) ->
  robot.respond /invite\s(.*)/i, (msg) ->
		user_name = msg.match[1]
		room = msg.message.user.room
		msg.robot.adapter.invite user_name, room

	robot.respond /groups[\s]?/i, (msg) ->
		user = msg.message.user
		console.log "----------------USER-----------------"
		console.log user
		msg.robot.adapter.get_group user

	robot.respond /nickname\sin\s(.*)/i, (msg) ->
		room = msg.match[1]
		user = msg.message.user
		msg.robot.adapter.get_nickname user, room


	robot.respond /create\sroom\s(.*)/i, (msg) ->
		room_name = msg.match[1]
		user = msg.message.user
		msg.robot.adapter.create_room user, room_name
