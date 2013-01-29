{Adapter,Robot,TextMessage,EnterMessage,LeaveMessage} = require 'hubot'

Xmpp    = require 'node-xmpp'
util    = require 'util'

class XmppBot extends Adapter
  run: ->
    options =
      username: process.env.HUBOT_XMPP_USERNAME
      password: process.env.HUBOT_XMPP_PASSWORD
      host: process.env.HUBOT_XMPP_HOST
      port: process.env.HUBOT_XMPP_PORT
      rooms:    @parseRooms process.env.HUBOT_XMPP_ROOMS.split(',')
      keepaliveInterval: 30000 # ms interval to send whitespace to xmpp server
      legacySSL: process.env.HUBOT_XMPP_LEGACYSSL
      preferredSaslMechanism: process.env.HUBOT_XMPP_PREFERRED_SASL_MECHANISM

    @robot.logger.info util.inspect(options)

    @client = new Xmpp.Client
      jid: options.username
      password: options.password
      host: options.host
      port: options.port
      legacySSL: options.legacySSL
      preferredSaslMechanism: options.preferredSaslMechanism

    @client.on 'error', @.error
    @client.on 'online', @.online
    @client.on 'stanza', @.read

    @options = options

  error: (error) =>
    @robot.logger.error error.toString()

  online: =>
    @robot.logger.info 'Hubot XMPP client online'

    @client.send new Xmpp.Element('presence')
    @robot.logger.info 'Hubot XMPP sent initial presence'

    @joinRoom room for room in @options.rooms
      
    # send raw whitespace for keepalive
    setInterval =>
      @client.send ' '
    , @options.keepaliveInterval

    @emit 'connected'

  parseRooms: (items) ->
    rooms = []
    for room in items
      index = room.indexOf(':')
      rooms.push
        jid:      room.slice(0, if index > 0 then index else room.length)
        password: if index > 0 then room.slice(index+1) else false
    return rooms

  # XMPP Joining a room - http://xmpp.org/extensions/xep-0045.html#enter-muc
  joinRoom: (room) ->
    @client.send do =>
      @robot.logger.debug "Joining #{room.jid}/#{@robot.name}"

      el = new Xmpp.Element('presence', to: "#{room.jid}/#{@robot.name}" )
      x = el.c('x', xmlns: 'http://jabber.org/protocol/muc' )
      x.c('history', seconds: 1 ) # prevent the server from confusing us with old messages
                                  # and it seems that servers don't reliably support maxchars
                                  # or zero values


      if (room.password) then x.c('password').t(room.password)
      return x

  # XMPP Leaving a room - http://xmpp.org/extensions/xep-0045.html#exit
  leaveRoom: (room) ->
    @client.send do =>
      @robot.logger.debug "Leaving #{room.jid}/#{@robot.name}"

      return new Xmpp.Element('presence', to: "#{room.jid}/#{@robot.name}", type: 'unavailable' )

  read: (stanza) =>
    if stanza.attrs.type is 'error'
      @robot.logger.error '[xmpp error]' + stanza
      return

    switch stanza.name
      when 'message'
        @readMessage stanza
      when 'presence'
        @readPresence stanza
      when 'iq'
        @readResult stanza

  readResult: (stanza) =>
    id = stanza.attrs.id
    [functionality, request_room] = id.split ":"
    console.log "-------FUNCTIONALITY-------------"
    console.log functionality
    console.log "-------REQUEST_ROOM--------------"
    console.log request_room
    switch functionality
      when 'group'
        @readGroup stanza
      when 'nickname'
        @readNickname stanza

  readNickname: (stanza) =>
    if stanza.attrs.type is 'result'
      result = stanza.getChild 'query'
      return unless result

      console.log "------------RESULT---------"
      console.dir result
      identity = result.getChild 'feature'
      console.log "---------------USER INDENTITY---------"
      console.dir identity
      console.log "---------------INDENTITY category-----"
      console.log identity.attrs.category

      console.log "---------------INDENTITY name -----"
      console.log identity.attrs.name

  readGroup: (stanza) =>
    if stanza.attrs.type is 'result'
      result = stanza.getChild 'query'
      return unless result

      items = result.getChildren 'item'
      message = []

      for e in items
        e_message = "JID: #{e.attrs.jid} \t NAME: #{e.attrs.name}"
        message.push e_message
      content = message.join "\n"
       
      user = {}
      user.room = (stanza.attrs.id.split ":")[1]
      user.type = "groupchat"
      @send user, content

  readMessage: (stanza) =>
    # ignore non-messages
    return if stanza.attrs.type not in ['groupchat', 'direct', 'chat']

    # ignore empty bodies (i.e., topic changes -- maybe watch these someday)
    body = stanza.getChild 'body'
    return unless body

    message = body.getText()

    console.log "------MESSAGE BPDY----------"
    console.log message
    [room, from] = stanza.attrs.from.split '/'
    @robot.logger.info "Received message: #{message} in room: #{room}, from: #{from}"

    # ignore our own messages in rooms
    return if from == @robot.name or from == @options.username or from is undefined

    # note that 'from' isn't a full JID, just the local user part
    user = @userForId from
    user.type = stanza.attrs.type
    user.room = room

    # console.log "----------------------ASK HUBOT TO WORK--------------------"
    @receive new TextMessage(user, message)

  readPresence: (stanza) =>
    jid = new Xmpp.JID(stanza.attrs.from)
    bareJid = jid.bare().toString()

    # xmpp doesn't add types for standard available mesages
    # note that upon joining a room, server will send available
    # presences for all members
    # http://xmpp.org/rfcs/rfc3921.html#rfc.section.2.2.1
    stanza.attrs.type ?= 'available'

    # Parse a stanza and figure out where it came from.
    getFrom = (stanza) =>
      if bareJid not in @options.rooms
        from = stanza.attrs.from
      else
        # room presence is stupid, and optional for some anonymous rooms
        # http://xmpp.org/extensions/xep-0045.html#enter-nonanon
        from = stanza.getChild('x', 'http://jabber.org/protocol/muc#user')?.getChild('item')?.attrs?.jid
      return from

    switch stanza.attrs.type
      when 'subscribe'
        @robot.logger.debug "#{stanza.attrs.from} subscribed to me"

        @client.send new Xmpp.Element('presence',
            from: stanza.attrs.to
            to:   stanza.attrs.from
            id:   stanza.attrs.id
            type: 'subscribed'
        )
      when 'probe'
        @robot.logger.debug "#{stanza.attrs.from} probed me"

        @client.send new Xmpp.Element('presence',
            from: stanza.attrs.to
            to:   stanza.attrs.from
            id:   stanza.attrs.id
        )
      when 'available'
        # for now, user IDs and user names are the same. we don't
        # use full JIDs as user ID, since we don't get them in
        # standard groupchat messages
        from = getFrom(stanza)
        return if not from?

        [room, from] = from.split '/'

        # ignore presence messages that sometimes get broadcast
        return if not @messageFromRoom room

        # If the presence is from us, track that.
        # Xmpp sends presence for every person in a room, when join it
        # Only after we've heard our own presence should we respond to
        # presence messages.
        if from == @robot.name or from == @options.username
          @heardOwnPresence = true
          return

        return unless @heardOwnPresence

        @robot.logger.debug "Availability received for #{from}"

        user = @userForId from, room: room, jid: jid.toString()

        @receive new EnterMessage user

      when 'unavailable'
        from = getFrom(stanza)

        [room, from] = from.split '/'

        # ignore presence messages that sometimes get broadcast
        return if not @messageFromRoom room

        # ignore our own messages in rooms
        return if from == @robot.name or from == @options.username

        @robot.logger.debug "Unavailability received for #{from}"

        user = @userForId from, room: room, jid: jid.toString()
        @receive new LeaveMessage(user)

  # Checks that the room parameter is a room the bot is in.
  messageFromRoom: (room) ->
    for joined in @options.rooms
      return true if joined.jid == room
    return false

  send: (user, strings...) ->
    for str in strings
      @robot.logger.info "Sending to #{user.room}: #{str}"

      params =
        to: if user.type in ['direct', 'chat'] then "#{user.room}/#{user.id}" else user.room
        type: user.type or 'groupchat'

      console.log "--------------MESSAGE SEND PARAMS ----------------"
      console.log params
      message = new Xmpp.Element('message', params).
                c('body').t(str)
     
      @client.send message

  reply: (user, strings...) ->
    for str in strings
      @send user, "#{user.name}: #{str}"

  topic: (user, strings...) ->
    string = strings.join "\n"

    message = new Xmpp.Element('message',
                to: user.room
                type: user.type
              ).
              c('subject').t(string)

    @client.send message


  get_group: (user) ->
    # user wants to get information of groups in his/her xmpp service
    room = user.room
    chat_service = (room.split "@")[1]

    message = new Xmpp.Element('iq',
      type: "get"
      to: chat_service
      id: "group:#{room}"
    ).
    c('query', xmlns: 'http://jabber.org/protocol/disco#items')

    @client.send message
    # Sad story here: @client.send will change the from into robot itself, 
    # then we lose the room where the command comes from
    # Thus, I need to find the solution for that. Now store the room info in id

  invite: (user_name, room) ->
    # invite user(user_name) as occupant in room
    user = @userForId user_name
    domain = (((room.split "@")[1]).split ".").slice(1).join(".")
    invitee = "#{user.id}@#{domain}"
    console.log "--------Invitee----------"
    console.log invitee

    message = new Xmpp.Element('message',to: room).
    c('x', xmlns: 'http://jabber.org/protocol/muc#user').
    c('invite', to: invitee).
    c('reason').t("You are pretty.")

    @client.send message

  get_nickname: (user, room) ->
    # user wants to get his/her nickname
    # but it is a joke, since @client.send will change the sender as a robot, fuck
    request_room = user.room
    chat_domain = (request_room.split "@")[1]
    server_domain = (chat_domain.split ".").slice(1).join(".")
    user = "#{user.id}@#{server_domain}"
    console.log "-------------USER------------"
    console.dir user
    room = "#{room}@#{chat_domain}"
    console.log "--------------ROOM-----------"
    console.log room

    message = new Xmpp.Element('iq',
      type: "get"
      to: room
      from: user
      id: "nickname:#{request_room}"
    ).
    c('query',
      xmlns: 'http://jabber.org/protocol/disco#info'
      node: 'x-roomuser-item')

    @client.send message

  create_room: (user, room_name) ->
    request_room = user.room
    chat_domain = (request_room.split "@")[1]
    nickname = @robot.name
    target_room_user = "#{room_name}@#{chat_domain}"
    console.log "------------Target Room---------"
    console.log target_room_user
    
    
    message_2 = new Xmpp.Element('iq',
      to: target_room_user
      type: "set"
      id: "create:#{request_room}")

    x = message_2.c('query', xmlns: 'http://jabber.org/protocol/muc#owner').c('x', 
      xmlns: 'jabber:x:data'
      type: 'submit')

    message_1 = new Xmpp.Element('presence', to: "#{room_name}@#{chat_domain}/#{nickname}").
    c('x', xmlns: 'http://jabber.org/protocol/muc').c('history', seconds: 1 )
    
  
    invite_message = new Xmpp.Element('message',to: target_room_user).
    c('x', xmlns: 'http://jabber.org/protocol/muc#user').
    c('invite', to: "kuno").
    c('reason').t("Fireman")

    @client.send message_1
    @client.send message_2
    
    @client.send invite_message
    
    


exports.use = (robot) ->
  new XmppBot robot

