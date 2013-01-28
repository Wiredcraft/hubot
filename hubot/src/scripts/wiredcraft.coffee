# Description:
#   The truth about wiredcraft.
#
# Commands:
#   hubot when is lunch time - Lunch time.
#   hubot where to go lunch - Alway to malatang.

module.exports = (robot) ->
  robot.respond /WHEN IS LUNCH TIME/i, (msg) ->
  	msg.send 'PM 1:30'

  robot.respond /WHERE TO GO LUNCH$/i, (msg) ->
    msg.send 'GO Malatang'

