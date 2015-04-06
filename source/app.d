module logircd;
import vibe.d;
import std.stdio;
import std.range;
import std.array;
import std.string;
import std.path : globMatch;
import core.stdc.ctype;
import numerics;
alias ajoin = std.array.join;

immutable string serverHostname;
immutable string serverMessagePrefix;
enum softwareFullname = "logircd 0.0.0";

static int sentMessageCounter = 0;

auto unroll(R)(R r)
{
  alias ET = ElementType!R;
  alias T = ElementType!ET;
  enum makeInputRange = isInputRange!R && isInputRange!ET;
  static assert(makeInputRange, "Only input ranges are implemented in unroll");
  static struct UnrollResult
  {
    R r;
    ET e;
    this(R r)
    {
      this.r = r;
      e = ET.init; /* this is BS XXX */
    }
    static if (makeInputRange)
    {
      void popFront()
      {
        if (!e.empty)
          e.popFront;
        while (e.empty && !r.empty) {
          e = r.front;
          r.popFront;
        }
      }
      @property bool empty()
      {
        return e.empty && r.empty;
      }
      @property T front()
      {
        if (e.empty)
          popFront;
        return e.front;
      }
    }
  }
  return UnrollResult(r);
}

class User {
  enum MODE_a = 1;
  enum MODE_i = 2;
  enum MODE_w = 4;
  enum MODE_r = 8;
  enum MODE_o = 16;
  enum MODE_O = 32;
  enum MODE_s = 64;
  uint bmodes;

  TCPConnection conn;
  
  protected string _nick, _canonicalNick, _userName, _hostName, _serverName, _realName, _nickUserHost;
  bool loggedIn;

  @property string nick() { return _nick; }
  @property string canonicalNick() { return _canonicalNick; }
  @property string username() { return _userName; }
  @property string hostname() { return _hostName; }
  @property string servername() { return _serverName; }
  @property string realname() { return _realName; }
  @property string nickUserHost() { return _nickUserHost; }

  void setNick(string nick)
  {
    _nick = nick;
    _canonicalNick = nick.toLower;
    updateNickUserHost;
  }
  void setUser(string userName, string hostName, string serverName, string realName)
  {
    _userName = userName;
    _hostName = hostName;
    _serverName = serverName;
    _realName = realName;
    updateNickUserHost;
  }
  void updateNickUserHost()
  {
    _nickUserHost = format("%s!%s@%s", nick, username, hostname);
  }

  bool ircop;
  UserChannel[string] channels;
  Task rtask, wtask;
  /* lastSentMessageId is used to make it easier to send a message to the union set
   * of groups of users (mostly, users in channels.)
   */
  uint lastSentMessageId;
  uint iid;
  this(TCPConnection conn, uint iid) {
    this.conn = conn;
    this.iid = iid;
    _nick = "*";
  }
  void send(string msg) {
    logInfo("(server) -> (%s:%d)\t%s", nick, iid, msg.stripRight);
    try {
      wtask.send(msg);
    } catch (Throwable o) {
      logInfo("%s:%d: uncaught exception for %s:%d in User.send(): %s"
      , o.file
      , o.line
      , nickUserHost
      , iid
      , o.msg
      );
    }
  }

  static bool validateNick(string s) {
    /* RFC 2812 Section 2.3.1 */
    /* i made up the < 3 part */
    if (s.length < 3 && s.length > 9)
      return false;
    if (!(s[0].isalpha || (s[0] >= 0x5B && s[0] <= 0x60) || (s[0] >= 0x7B && s[0] <= 0x7D)))
      return false;
    foreach (c; s[1..$]) {
      if (!(c.isalpha || c.isdigit || c == '-' || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7D)))
        return false;
    }
    return true;
  }

  /* The second argument is XXX BULLSHIT XXX */
  void joinChannel(string chanName, ref Channel[string] chans)
  {
    if (!Channel.validateName(chanName)) {
      this.tx403(chanName);
      return;
    }

    /* Channel exists or create it? */
    auto canonicalChanName = chanName.toLower;
    auto chanPtr = canonicalChanName in chans;
    bool chanExisted = chanPtr !is null;
    Channel chan;
    UserChannel uc;

    if (chanExisted)
    {
      /* Is user already in channel? */
      auto ucPtr = canonicalChanName in this.channels;
      if (ucPtr !is null && ucPtr.joined)
      {
        /* Do nothing */
        logInfo("  user already in channel");
        return;
      }

      chan = *chanPtr;

      /* This should only exist if the user has been given +i on this chan,
       * since we have already confirmed that chanName !in this.channels
       * XXX BS
       */
      if (ucPtr !is null)
        uc = *ucPtr;

      /* Check for invitation? */
      if (chan.bmodes & Channel.MODE_i)
      {
        if (uc is null || !uc.invited)
        {
          /* ERR_INVITEONLYCHAN */
          this.txsn!"473 %s %s :Cannot join channel (+i)"(chan.name);
          return;
        }
      }

      /* Check for ban exception */
      bool banExcepted;
      foreach (eban; chan.ebans)
      {
        if (eban.matches(this))
        {
          banExcepted = true;
          break;
        }
      }

      /* Check for bans */
      if (!banExcepted)
      {
        foreach (ban; chan.bans)
        {
          if (ban.matches(this))
          {
            this.txsn!"474 %s %s :Cannot join channel (+b)"(chan.name);
            return;
          }
        }
      }
    }
    else
    {
      /* Chan doesn't exist. Create new channel */
      chan = new logircd.Channel(chanName);
    }

    /* Fiddle with some things to officially join the user to the channel */
    if (uc is null)
      uc = chan.join(this);
    else
    {
      uc.invited = false;
      uc.joined = true;
    }

    if (!chanExisted)
      uc.channelOperator = true;
    /* Broadcast JOIN message */
    chan.joinedUsers.txum!"JOIN %s"(this, chan.name);
    /* Send this user topic */
    if (chan.topic) {
      /* 332 RPL_TOPIC */
      this.txsn!"332 %s %s :%s"(chan.name, chan.topic);
      /* 333 RPL_TOPICWHOTIME */
      this.txsn!"333 %s %s %s"(chan.name, chan.topicWhoTime);
    } else {
      /* 331 RPL_NOTOPIC */
      this.txsn!"331 %s %s :No topic set"(chan.name);
    }
    /* Send user NAMES */
    this.txsn!"353 %s @ %s :%s"(chan.name, chan.names);
    this.txsn!"366 %s %s :End of /NAMES list."(chan.name);
    /* WHO response
    this.txsn!"315 %s %s :End of /WHO list."(chan.name);
    */

    if (!chanExisted)
    {
      logInfo("  Creating channel \"%s\"", chanName);
      chans[chan.canonicalName] = chan;
    }
    return;
  }

  /* command = "PART" | "QUIT" */
  void partAll(string command, string reason) {
    channels.values
    .map!((UserChannel uc){return uc.chan.otherJoinedUsers(this);})
    .unroll
    .txum!"%s :%s"(this, command, reason)
    ;

    foreach (uc; channels)
    {
      /* This should ALWAYS be true! */
      if (iid in uc.chan.users)
        uc.chan.users.remove(iid);
    }
  }

  bool isAway;
  string awayMessage;
}

struct Ban {
  string mask;
  string authorNick;
  ulong time;
  bool matches(User user)
  {
    return globMatch(user.nickUserHost, mask);
  }
}

class Channel {
  string name;
  string canonicalName;
  string topic;
  string topicWhoTime;
  Ban[string] bans; /* key = mask */
  Ban[string] ebans; /* ban exceptions; key = mask */

  /* Boolean channel modes */
  enum MODE_n = 0x00000001;    /* NO_EXTERNAL_MSGS */
  enum MODE_t = 0x00000002;    /* TOPIC_LOCK */
  enum MODE_s = 0x00000004;    /* SECRET */
  enum MODE_i = 0x00000008;    /* INVITE */
  enum MODE_m = 0x00000010;    /* MODERATED */
  static immutable uint MODES[char];

  static this()
  {
    MODES = [
      'n': MODE_n
    , 't': MODE_t
    , 's': MODE_s
    , 'i': MODE_i
    , 'm': MODE_m
    ];
  }

  uint bmodes;
  ulong modeTime; // when mode was set

  UserChannel[uint] users;

  this(string name) {
    this.name = name;
    canonicalName = name.toLower;
  }
  UserChannel join(User user) {
    auto uc =
    user.channels[canonicalName] =
    users[user.iid] =
      new UserChannel(user, this);
    uc.joined = true;
    return uc;
  }
  UserChannel invite(User user) {
    auto uc =
    user.channels[canonicalName] =
    users[user.iid] =
      new UserChannel(user, this);
    uc.invited = true;
    return uc;
  }

  void setBooleanMode(User actor, uint mode, bool on)
  {
    if (actor.iid !in users)
    {
      actor.txsn!"442 %s %s :You're not in that channel."(name);
      return;
    }

    bmodes &= ~mode;
    if (on)
      bmodes |= mode;
  }

  void setTopic(User author, string topic) {
    this.topic = topic;
    topicWhoTime = format("%s!%s@%s %d", author.nick, author.username, author.hostname, core.stdc.time.time(null));

    /* Broadcast new topic */
    foreach (user; users) {
      /* 332 RPL_TOPIC */
      user.user.send(format(":%s 332 %s %s :%s\r\n", serverHostname, user.user.nick, name, topic));
      /* 333 RPL_TOPICWHOTIME */
      user.user.send(format(":%s 333 %s %s %s\r\n", serverHostname, user.user.nick, name, topicWhoTime));
    }
  }

  void sendNAMES(User recipient) {
    recipient.txsn!"353 %s @ %s :%s"(name, names);
    recipient.txsn!"366 %s %s :End of /NAMES list."(name);
  }

  string names() {
    return cast(string) std.array.join(map!((UserChannel uc){
      return format("%s%s", uc.channelOperator?"@":"", uc.user.nick);
    })(users.values), " ");
  }

  auto joinedUsers() {
    return users.values
    .filter!((UserChannel uc){return uc.joined;})
    .map!((UserChannel uc){return uc.user;});
  }

  auto otherJoinedUsers(User exclude) {
    return users.values
    .filter!((UserChannel uc){return uc.joined && uc.user !is exclude;})
    .map!((UserChannel uc){return uc.user;});
  }

  UserChannel userJoined(uint iid) {
    return iid in users && users[iid].joined ? users[iid] : null;
  }

  string modeString() {
    char[32] buf;
    size_t i;
    buf[i++] = '+';
    if (bmodes & MODE_n) buf[i++] = 'n';
    if (bmodes & MODE_t) buf[i++] = 't';
    if (bmodes & MODE_s) buf[i++] = 's';
    if (bmodes & MODE_i) buf[i++] = 'i';
    if (bmodes & MODE_m) buf[i++] = 'm';
    return buf[0..i].idup;
  }

  static bool validateName(string s) {
    /* RFC 2812 Section 1.3 -- fuck that rubbish */
    if (s.length < 2 || s.length > 50)
      return false;
    if (s[0] != '#')
      return false;
    foreach (c; s[1..$])
      if (!c.isalpha && !c.isdigit)
        return false;
    return true;
  }
}

/* Representation of user-channel relationship */
class UserChannel {
  User user;
  Channel chan;
  enum MODE_o = 1;
  enum MODE_h = 2;
  enum MODE_v = 4;
  uint bmodes;
  @property bool channelOperator()            { return (bmodes & MODE_o) != 0; }
  @property bool channelHalfOperator()        { return (bmodes & MODE_h) != 0; }
  @property bool channelVoice()               { return (bmodes & MODE_v) != 0; }
  @property void channelOperator(bool v)      { if (v) bmodes |= MODE_o; else bmodes &= ~MODE_o; }
  @property void channelHalfOperator(bool v)  { if (v) bmodes |= MODE_h; else bmodes &= ~MODE_h; }
  @property void channelVoice(bool v)         { if (v) bmodes |= MODE_v; else bmodes &= ~MODE_v; }
  bool joined;
  bool invited;
  this(User user, Channel chan) {
    this.user = user;
    this.chan = chan;
  }
}

string coerceAscii(string s) {
  char[] r;
  r.reserve(s.length);
  foreach (c; s)
    if (c == '\\')
      r ~= "\\\\";
    else if (c >= ' ' && c < 127)
      r ~= c;
    else
      r ~= format("\\x%02x", c);
  return cast(string) r;
}

void txsn(string fmt, T...)(User user, T a) {
  auto FMT = serverMessagePrefix ~ fmt ~ "\r\n";
  try { user.send(format(FMT, user.nick, a)); }
  catch(Throwable o) {
    logInfo("error: txsn!\"%s\"(%s)", FMT, T.stringof);
    logInfo("  exception: %s", o);
  }
}
void txsn(string fmt, R, T...)(R users, T a)
if (isInputRange!R && is(ElementType!R : User))
{
  auto FMT = serverMessagePrefix ~ fmt ~ "\r\n";
  try {
  foreach (user; users)
    user.send(format(FMT, user.nick, a));
  }
  catch(Throwable o) {
    logInfo("error: txsn!\"%s\"(%s)", FMT, T.stringof);
    logInfo("  exception: %s", o);
  }
}

void txum(string fmt, T...)(User recipient, User user, T a)
{
  /* TODO use user.nickUserHost */
  recipient.send(format(":%s!%s@%s " ~ fmt ~ "\r\n", user.nick, user.username, user.hostname, a));
}
void txum(string fmt, R, T...)(R recipients, User user, T a)
if (isInputRange!R && is(ElementType!R : User))
{
  sentMessageCounter++;
  /* TODO use user.nickUserHost */
  auto msg = format(":%s!%s@%s " ~ fmt ~ "\r\n", user.nick, user.username, user.hostname, a);
  foreach (recipient; recipients)
  {
    if (recipient.lastSentMessageId != sentMessageCounter)
    {
      recipient.send(msg);
      recipient.lastSentMessageId = sentMessageCounter;
    }
  }
}

/* RPL_WHOREPLY */
void tx352(User recipient, User whoUser, string chanName="*") {
  auto hereOrGone = 'H'; // TODO implement AWAY
  auto modeString = "x"; // i think asterisk at beginning might mean ircop
  auto hopCount = 3;
  recipient.txsn!"352 %s %s %s %s %s %s %c%s :%d %s"(
    chanName
  , whoUser.username
  , whoUser.hostname
  , serverHostname // this would be variable if logircd could network
  , whoUser.nick
  , hereOrGone
  , modeString
  , hopCount // this would be variable if logircd could network
  , whoUser.realname
  );
}
/* ERR_NOSUCHCHANNEL */
void tx403(User user, string channame) { user.txsn!"403 %s %s :No such channel"(channame); }
/* ERR_USERNOTINCHANNEL */
void tx441(User user, string channame, string nick) { user.txsn!"442 %s %s %s :They aren't on that channel"(channame, nick); }
/* ERR_NOTONCHANNEL */
void tx442(User user, string channame) { user.txsn!"442 %s %s :You're not in that channel"(channame); }
/* ERR_NOSUCHNICK */
void tx401(User user, string nickname) { user.txsn!"401 %s %s :No such nick"(nickname); }
/* ERR_NEEDMOREPARAMS */
void tx461(User user, string command) { user.txsn!"461 %s %s :Not enough parameters"(command); }
/* ERR_CANNOTSENDTOCHAN */
void tx404(User user, string chanName) { user.txsn!"404 %s %s :Cannot send to channel"(chanName); }
/* ERR_CHANOPRIVSNEEDED */
void tx482(User user, string channame) { user.txsn!"482 %s %s :You're not channel operator"(channame); }

struct QuitMessage { }

immutable bool[string] prelaunchCommands;
shared static string SpecialString = "<SpecialString>";
shared static this() {
  import std.stdio : writeln;
  auto serverCTime = core.stdc.time.time(null);
  auto serverCTimeTm = core.stdc.time.localtime(&serverCTime);
  char[] buf = new char[200];
  auto serverCTimeStrLen = core.stdc.time.strftime(buf.ptr, buf.length, "%a %b %d %Y at %T %Z", serverCTimeTm);
  if (serverCTimeStrLen >= 199 || serverCTimeStrLen <= 0)
    throw new Exception("strftime() buf size too large");
  auto serverCTimeStr = buf[0..serverCTimeStrLen];
  buf = null;
  /* So, the actual format we get with this code is: Fri Apr 03 2015 at 13:32:34 PDT
   * but AfterNet gives me Sat Jul 5 2014 at 23:39:00 EDT. The subtle difference being
   * that the day-of-the-month is not zero-padded by AfterNet. For now, I'm just gonna
   * leave it like this and assume it will work. *cross fingers*
   */
  serverHostname = "logircd-server";//to!string(core.stdc.stdlib.getenv("HOSTNAME"));
  serverMessagePrefix = ":" ~ serverHostname ~ " ";
  prelaunchCommands = ["USER": true, "NICK": true, "QUIT": true, "PASS": true];

  uint iidCounter;
  string srvCmdFmt = ":logircd %s %s :%s\r\n";
  logircd.Channel[string] channels; // keyed by Channel.canonicalName
  User[string] usersByNick;
  User[uint] usersByIid;

  listenTCP(6667, (conn) {
    logInfo("New client!");
    string quitReason = "No reason given.";
    auto user = new User(conn, iidCounter);
    usersByIid[iidCounter] = user;
    iidCounter++;
    bool quit = false;

    void sendMessage(string cmd, string msg) {
      user.send(format(srvCmdFmt, cmd, user.nick, msg));
    }

    void maybeWelcomeUser()
    {
      if (user.loggedIn || user._nick == "*" || !user._userName)
        return;
      user.loggedIn = true;

      user.txsn!"001 %s :Welcome to LogIRCd, %s"(user.nick);
      user.txsn!"002 %s :Your host is %s, running %s"(serverHostname, softwareFullname);
      user.txsn!"003 %s :This server was created %s"(serverCTimeStr);
      user.txsn!"004 %s %s %s a aioOw abehiIklmnostv"(serverHostname, softwareFullname);
      user.txsn!"251 %s :There are %d users and 0 invisible on 1 servers"(usersByNick.length);
      user.txsn!"252 %s 0 :operator(s) online";
      user.txsn!"372 %s :This is the message of the day!";
      user.txsn!"376 %s :End of /MOTD command.";

      user.txum!"MODE %s +x"(user, user.nick);
      user.joinChannel("#general", channels);
    }

    string[][] commandQueue;

    scope(exit)
    {
      logInfo(":::scope(exit) broadcasting QUIT");
      usersByIid.remove(user.iid);
      usersByNick.remove(user.canonicalNick);
      if (conn.connected)
        conn.close;
    }

    user.rtask = runTask({
      import std.stdio;
      while (!quit && conn.connected)
      {
        try
        {
          auto line = cast(string) conn.readLine(4096, "\n");
          if (line.length == 0)
            continue;
          if (line[$-1] == '\r')
            line = line[0..$-1];
          logInfo("(server) <- (%s:%d)\t %s", user.nick, user.iid, line);
          string[] words;
          bool colonArg; // set to true if the last param began with a colon
          words.reserve(16);
          string lineParser = line;
          while (lineParser.length) {
            auto n = lineParser.indexOf(' ');
            auto m = lineParser.indexOf(':');
            if (n < 0) {
              words ~= lineParser[0..$];
              lineParser.length = 0;
              break;
            }
            words ~= lineParser[0..n];
            if (m == n+1) {
              words ~= lineParser[m+1..$];
              lineParser.length = 0;
              colonArg = true;
              break;
            }
            lineParser = lineParser[n+1..$];
          }
          logInfo("command parsed: \"%s\"", std.array.join(words, "\", \""));
          auto cmd = words[0];
          if (!user.loggedIn && cmd !in prelaunchCommands)
          {
            if (commandQueue.length >= 32)
            {
              sendMessage("NOTICE", "Sorry, you need to NICK and USER successfully before you can use this server!");
              quit = true;
              break;
            }
            commandQueue ~= words;
            continue;
          }
          switch (cmd) {
            case "CAP":
              if (words.length == 2 && words[1] == "LS")
                user.txsn!"CAP %s LS :account-notify away-notify userhost-in-names";
              // TODO REQ -> ACK
              break;
            case "NICK":

              logInfo("  current nicks %d", usersByNick.length);
              foreach (nick; usersByNick.keys)
                logInfo("    \"%s\"", nick);

              if (words.length < 2)
              {
                user.txsn!"431 %s :No nick given.";
                break;
              }

              auto wantedNick = words[1];
              auto canonicalWantedNick = wantedNick.toLower;

              auto nickFound = canonicalWantedNick in usersByNick;
              if (nickFound !is null)
              {
                user.txsn!"433 %s %s :Nick already in use."(wantedNick);
                break;
              }

              if (!User.validateNick(wantedNick))
              {
                user.txsn!"432 %s %s :Erroneous nickname."(wantedNick);
                break;
              }

              logInfo("  assigning new nick \"%s\" -> \"%s\"", user.nick, wantedNick);

              user.channels.values
              .map!"a.chan.users.values"
              .unroll
              .map!"a.user"
              .txum!"NICK %s"(user, wantedNick)
              ;
              if (user.lastSentMessageId != sentMessageCounter)
              {
                user.txum!"NICK %s"(user, wantedNick);
                user.lastSentMessageId = sentMessageCounter;
              }

              logInfo("  searching for canonical nick \"%s\"", canonicalWantedNick);
              nickFound = user.canonicalNick in usersByNick;
              if (nickFound !is null)
              {
                logInfo("  removing nick!");
                usersByNick.remove(user.canonicalNick);
                logInfo("  new nick count: %d", usersByNick.length);
              }
              logInfo("  adding nick!");
              usersByNick[canonicalWantedNick] = user;
              logInfo("  new nick count: %d", usersByNick.length);

              user.setNick(wantedNick);
              maybeWelcomeUser;
              break;
            case "USER":
              /* TODO parse this correctly (look for the colon) */
              if (words.length < 5)
              {
                logInfo("    malformed USER command TODO handle this");
              }
              else
              {
                user.setUser(words[1], words[2], words[3], words[4]);
                maybeWelcomeUser;
              }
              break;

            case "TOPIC":
              auto targetName = words[1].toLower;
              auto chanPtr = targetName in channels;
              if (chanPtr is null)
              {
                user.tx403(words[1]);
                break;
              }
              auto chan = *chanPtr;
              if (words.length == 2) {
                /* Retrieve topic */
                if (chan.topic) {
                  /* 332 RPL_TOPIC */
                  user.txsn!"332 %s %s :%s"(chan.name, chan.topic);
                  /* 333 RPL_TOPICWHOTIME */
                  user.txsn!"333 %s %s %s"(chan.name, chan.topicWhoTime);
                } else {
                  /* 331 RPL_NOTOPIC */
                  user.txsn!"331 %s %s :No topic set"(chan.name);
                }
              } else if (words.length > 2) {
                auto ucPtr = user.iid in chan.users;
                /* I guess we'll block topic from being changed by outsiders if chan mode +n */
                if ((ucPtr is null || !ucPtr.joined) && ((chan.bmodes & Channel.MODE_n) != 0))
                {
                  user.tx442(chan.name);
                  break;
                }
                /* Respect chan mode +t */
                if ((ucPtr is null || !ucPtr.joined || !ucPtr.channelOperator) && ((chan.bmodes & Channel.MODE_t) != 0))
                {
                  user.tx482(chan.name);
                  break;
                }
                /* Set topic */
                chan.setTopic(user, words[2]);
              }
              else sendMessage("NOTICE", "Sorry, logircd did not understand your TOPIC command");
              break;

            case "MODE":
              if (words.length >= 2)
              {
                auto target = words[1];
                auto canonicalTarget = target.toLower;
                /* Target is a channel? */
                if (target[0] == '#')
                {
                  /* ERR_NOSUCHCHANNEL */
                  auto chanPtr = canonicalTarget in user.channels;
                  if (chanPtr is null)
                  {
                    user.tx403(target);
                    break;
                  }

                  auto chan = (*chanPtr).chan;

                  /* XXX ??? RPL_CHANNELMODEIS Afternet and Freenode gave me 324 followed by 329 */
                  if (words.length == 2)
                  {
                    user.txsn!"324 %s %s %s"(chan.name, chan.modeString);
                    user.txsn!"329 %s %s %s"(chan.name, chan.modeTime);
                    break;
                  }

                  /* Check for ops */
                  auto ucPtrOper = chan.canonicalName in user.channels;
                  if (ucPtrOper is null || !ucPtrOper.channelOperator)
                  {
                    user.tx482(chan.name);
                    break;
                  }

                  auto modeOpts = words[2];

                  if (words.length >= 3) // TODO remove condition
                  {
                    auto modes = chan.bmodes;
                    auto modeMask = modes.max;
                    auto modeSet = modes.init;

                    bool modeSign = true;
                    size_t iModeArg = 3;

                    string[][char][bool] echoUCModesChanged;

                    foreach (c; modeOpts)
                    {
                      switch (c)
                      {
                        case '+':
                          modeSign = true;
                          break;
                        case '-':
                          modeSign = false;
                          break;
                        case 'n': case 't': case 's': case 'i': case 'm':
                          auto modeBit = Channel.MODES[c];
                          if (((modes & modeBit) != 0) != modeSign)
                          {
                            echoUCModesChanged[modeSign][c] ~= SpecialString;
                            if (modeSign) modes |= modeBit;
                            else          modes &= ~modeBit;
                          }
                          break;

                        case 'e':
                        case 'b':
                          auto bans = c == 'b' ? &chan.bans : &chan.ebans;
                          if (iModeArg >= words.length)
                          {
                            /* List bans */
                            /* RPL_BANLIST */
                            foreach (ban; (*bans).values)
                              user.txsn!"367 %s %s %s %s %d :Banned"(chan.name, ban.mask, ban.authorNick, ban.time);
                            /* RPL_ENDOFBANLIST */
                            user.txsn!"368 %s %s :End of channel ban list"(chan.name);
                          }
                          else
                          {
                            auto banMask = words[iModeArg++];
                            auto banPtr = banMask in *bans;
                            if ((banPtr !is null) != modeSign)
                            {
                              echoUCModesChanged[modeSign][c] ~= banMask;
                              if (modeSign) (*bans)[banMask] = Ban(banMask, user.nick, core.stdc.time.time(null));
                              else          (*bans).remove(banMask);
                            }
                          }
                          break;

                        case 'o':
                        case 'h':
                        case 'v':
                          if (iModeArg >= words.length)
                          {
                            /* Do nothing */
                            /* Freenode and Afternet both do nothing */
                          }
                          else
                          {
                            auto targetNick = words[iModeArg++].toLower;
                            auto targetUser = usersByNick[targetNick];
                            auto targetBit =
                              c == 'o' ? UserChannel.MODE_o
                            : c == 'h' ? UserChannel.MODE_h
                            :/* == 'v'*/ UserChannel.MODE_v
                            ;
                            targetNick = targetUser.nick;
                            auto ucPtr = targetUser.iid in chan.users;
                            if (ucPtr !is null && ((ucPtr.bmodes & targetBit) != 0) != modeSign)
                            {
                              echoUCModesChanged[modeSign][c] ~= targetNick;
                              if (modeSign) ucPtr.bmodes |= targetBit;
                              else          ucPtr.bmodes &= ~targetBit;
                            }
                          }
                        break;

                        default:
                          /* ERR_UNKNOWNMODE */
                          user.txsn!"472 %s %c :is unknown mode char to %s"(c, softwareFullname);
                      }
                    }

                    chan.bmodes = modes;
                    chan.modeTime = core.stdc.time.time(null);

                    char[] modeChangeFeedback;

                    foreach (modeSign, foo; echoUCModesChanged)
                    {
                      bool any;
                      foreach (modeChar, bar; foo)
                      {
                        if (!any)
                        {
                          modeChangeFeedback ~= modeSign ? '+' : '-';
                          any = true;
                        }
                        modeChangeFeedback ~= modeChar;
                      }
                    }

                    foreach (modeSign, foo; echoUCModesChanged)
                    {
                      foreach (modeChar, bar; foo)
                      {
                        foreach (baz; bar)
                        {
                          if (baz !is SpecialString)
                          {
                            modeChangeFeedback ~= ' ';
                            modeChangeFeedback ~= baz;
                          }
                        }
                      }
                    }

                    chan.joinedUsers.txum!"MODE %s %s"(user, chan.name, modeChangeFeedback);
                    break;
                  }

                  assert(0, "AAA499");
                }
              }
              sendMessage("NOTICE", "Sorry, that invocation of MODE has not been implemented.");
              break;

            case "AWAY":
              string awayCommandBroadcast;
              if (words.length == 1)
              {
                user.isAway = false;
                /* RPL_UNAWAY */
                user.txsn!"305 %s :You are no longer marked as being away";
                awayCommandBroadcast = cmd;
              }
              else
              {
                user.isAway = true;
                user.awayMessage = words[1];
                /* RPL_NOWAWAY */
                user.txsn!"306 %s :You have been marked as being away";
                awayCommandBroadcast = format("AWAY :%s", words[1]);
              }
              /* Broadcast AWAY command to joined channels */
              foreach (uc; user.channels)
              {
                if (uc.joined)
                {
                  // slightly inefficient, oh well
                  uc.chan.otherJoinedUsers(user).txum!"%s"(user, awayCommandBroadcast);
                }
              }
              break;

            case "KICK":
              if (words.length <= 2)
              {
                user.tx461(cmd);
                break;
              }
              kick(user, words[1..colonArg ? $-1 : $], colonArg ? words[$-1] : user.nick, channels, usersByNick);
              break;

            case "ISON":
              if (words.length == 1)
              {
                user.tx461(cmd);
                break;
              }
              auto people = 
                words[1..$]
                .map!((string nick) {
                  auto userPtr = nick.toLower in usersByNick;
                  return (userPtr !is null && (((*userPtr).bmodes & User.MODE_i) == 0))
                    ? (*userPtr).nick : null;
                })
                .filter!"a !is null"
                .ajoin(" ")
                ;
              user.txsn!"302 %s %s"(people);
              break;

            case "PART":
              if (words.length < 2)
              {
                user.tx461("PART");
                break;
              }

              auto chanName = words[1].toLower;

              auto ucPtr = chanName in user.channels;
              if (ucPtr is null)
              {
                user.tx442(chanName);
                break;
              }

              auto chan = (*ucPtr).chan;

              //pragma(msg, (ElementType!(ReturnType!(Channel.joinedUsers))));
              //pragma(msg, (isInputRange!(ReturnType!(Channel.joinedUsers))));
              chan.joinedUsers.txum!"PART %s %s"(user, chan.name, words.length >= 3 ? words[2] : "No reason given");

              user.channels.remove(chanName);
              chan.users.remove(user.iid);
              break;

            case "INVITE":
              if (words.length == 1)
              {
                /* TODO list invites */
              }
              else if (words.length >= 3)
              {
                auto targetNick = words[1];
                auto canonicalTargetNick = targetNick.toLower;
                auto targetChan = words[2];
                if (targetChan !in channels)
                {
                  user.tx403(targetChan);
                  break;
                }
                auto canonicalTargetChan = targetChan.toLower;
                if (canonicalTargetChan !in user.channels)
                {
                  user.tx442(targetChan);
                  break;
                }
                if (canonicalTargetNick !in usersByNick)
                {
                  user.tx401(targetNick);
                  break;
                }
                auto targetUser = usersByNick[canonicalTargetNick];
                targetNick = targetUser.nick;
                auto chan = channels[canonicalTargetChan];
                if (chan.userJoined(targetUser.iid) !is null)
                {
                  /* ERR_USERONCHANNEL */
                  user.txsn!"443 %s %s %s :is already on channel"(targetNick, chan.name);
                  break;
                }
                /* RPL_INVITING - according to experience and alien.net.au, RFC1459 has it wrong! */
                user.txsn!"341 %s %s %s"(targetNick, chan.name);
                targetUser.txum!"INVITE %s %s"(user, targetNick, chan.name);
                chan.invite(targetUser);
              }
              break;

            case "JOIN":
              if (words.length < 2)
              {
                /* ERR_NEEDMOREPARAMS */
                user.tx461(words[0]);
                break;
              }
              user.joinChannel(words[1], channels);
              break;

            case "PRIVMSG":
              if (words.length < 3)
              { /* TODO */ }
              else {
                auto target = words[1].toLower;
                auto targetUserPtr = target in usersByNick;
                if (targetUserPtr !is null)
                {
                  (*targetUserPtr).txum!"PRIVMSG %s :%s"(user, (*targetUserPtr).nick, words[2]);
                  if (targetUserPtr.isAway)
                    user.txsn!"301 %s %s :%s"(targetUserPtr.nick, targetUserPtr.awayMessage);
                  break;
                }
                auto targetChanPtr = target in channels;
                if (targetChanPtr !is null)
                {
                  auto chan = *targetChanPtr;
                  auto ucPtr = target in user.channels;
                  if ((chan.bmodes & Channel.MODE_n) && (ucPtr is null || !ucPtr.joined))
                  {
                    user.tx404(chan.name); // TODO give reason?
                    break;
                  }
                  if ((chan.bmodes & Channel.MODE_m) && (ucPtr is null || !ucPtr.channelVoice))
                  {
                    user.tx404(chan.name); // TODO give reason?
                    break;
                  }
                  chan.otherJoinedUsers(user).txum!"PRIVMSG %s :%s"(user, chan.name, words[2]);
                }
              }
              break;
            case "PING":
              /* Only implementing PING from client. xchat2 doesn't send PING spuriously, it seems,
               * but irssi does, and disconnects after 301 seconds on my system. Also, we assume that
               * we are the one being pinged! XXX */
              if (words.length == 2) {
                /* This is how AfterNET responded... XXX TODO */
                user.txsn!"PONG %s :%s"(words[1]);
              } else {
                user.txsn!"PONG %s";
              }
              break;
            case "QUIT":
              quitReason = words.length > 1 ? words[1] : "No reason given.";
              quit = true;
              break;
            case "LIST":
              /* RPL_LISTSTART */
              /* lol what does this message even mean? silly afternet */
              user.txsn!"321 %s Channel :Users  Name";
              auto channelNames = words.length == 1 ? channels.keys : words[1].split(',');
              foreach (cname; channelNames) {
                if (cname in channels) {
                  auto chan = channels[cname.toLower];
                  /* Hide +s channels */
                  if ((chan.bmodes & Channel.MODE_s) && user.iid !in chan.users)
                    continue;
                  /* RPL_LIST */
                  user.txsn!"322 %s %s %d :%s"(chan.name, chan.users.length, chan.topic);
                }
              }
              /* RPL_LISTEND */
              user.txsn!"323 %s :End of /LIST";
              break;
              
              case "WHO":
                string[] whoMasks = words[1..$];
                bool ircops;
                if (whoMasks.length && whoMasks[$-1] == "o")
                {
                  ircops = true;
                  whoMasks = whoMasks[0..$-1];
                }
                if (whoMasks.length == 0)
                {
                  whoMasks = ["*"];
                }

                sentMessageCounter++;
                foreach (whoMask; whoMasks)
                {
                  /* So, on AfterNet, the "channel" that gets listed seems to be arbitrary,
                   * but the 352 replies are IN ORDER of channel. Yet, no user shares more than
                   * one channel in common with the WHO invoker is listed more than once. I think
                   * I can live with that behavior.
                   */
                  /* TODO implement user mode +i */
                  Channel* chanPtr;
                  if (whoMask == "*")
                  {
                    foreach (whoUser; usersByIid)
                    {
                      if (whoUser.lastSentMessageId == sentMessageCounter || (ircops && !whoUser.ircop))
                        continue;
                      user.tx352(whoUser);
                      user.lastSentMessageId = sentMessageCounter;
                    }
                  }
                  else if ((chanPtr = whoMask.toLower in channels) !is null)
                  {
                    auto chan = *chanPtr;
                    foreach (whoUc; chan.users)
                    {
                      auto whoUser = whoUc.user;
                      if (whoUser.lastSentMessageId == sentMessageCounter)
                        continue;
                      if (!(ircops && !whoUser.ircop))
                      {
                        user.tx352(whoUser, chan.name);
                        whoUser.lastSentMessageId = sentMessageCounter;
                      }
                    }
                  }
                  else
                  {
                    foreach (whoUser; usersByIid)
                    {
                      if (whoUser.lastSentMessageId == sentMessageCounter)
                        continue;
                      if (!(ircops && !whoUser.ircop)
                      &&(globMatch(whoUser.nick, whoMask)
                      || globMatch(whoUser.username, whoMask)
                      || globMatch(whoUser.hostname, whoMask)
                      ))
                      {
                        user.tx352(whoUser);
                        whoUser.lastSentMessageId = sentMessageCounter;
                      }
                    }
                  }
                }
                user.txsn!"315 %s * :End of /WHO list.";
                break;

            default:
              sendMessage("NOTICE", format("*** Unknown command: %s", words[0]));
              break;
          }
        }
        catch (Throwable o)
        {
          logInfo("%s:%d: uncaught exception for %s:%d in rtask: %s"
          , o.file
          , o.line
          , user.nickUserHost
          , user.iid
          , o.msg
          );
          quit = true;
          quitReason = "Error reading from socket.";
        }
      }
      logInfo(":::leaving rtask scope for %s:%d", user.nick, user.iid);
    });

    user.wtask = runTask({
      while (!quit && conn.connected) { try {
        logInfo(":::wtask starting for %s:%d quit = %s", user.nick, user.iid, quit);
        receive(
          (QuitMessage qm)
          {
            quit = true; /* should already be true, oh well */
            logInfo(":::wtask received QuitMessage for %s:%d quit = %s", user.nick, user.iid, quit);
          },
          (string s) {
            conn.write(s);
          }
        );
      } catch (InterruptException o) {
        logInfo(":::wtask interrupted for %s:%d", user.nickUserHost, user.iid);
        if (!quit) {
          quit = true;
          quitReason = "write task interrupted";
        }
      } catch (Throwable o) {
        logInfo("%s:%d: uncaught exception for %s:%d in wtask: %s"
        , o.file
        , o.line
        , user.nickUserHost
        , user.iid
        , o.msg
        );
        quit = true;
        quitReason = "Error writing to socket.";
      }
    }});

    sendMessage("NOTICE", "*** Welcome to the server!");

    user.rtask.join;
    user.partAll("QUIT", quitReason);
    user.wtask.send(QuitMessage());
    user.wtask.join;

    logInfo(":::Reached end of connection control scope");
  });

  logInfo("Please connect via irc client.");
}

void kick(User kicker, string[] args, string reason, Channel[string] chans, User[string] usersByNick)
{
  if (args.length < 2)
  {
    kicker.tx461("KICK");
    return;
  }
  Channel[] kickChans;
  User[] kickUsers; // maybe we'll kick a user redundantly, oh well
  foreach (iTargetName, targetName; args)
  {
    if (kickUsers.length == 0 && targetName[0] == '#')
    {
      auto targetChanPtr = targetName in chans;
      if (targetChanPtr is null)
      {
        /* ERR_NOSUCHCHANNEL */
        kicker.tx403(targetName);
        return;
      }
      kickChans ~= *targetChanPtr;
      continue;
    }

    auto targetUserPtr = targetName.toLower in usersByNick;
    if (targetUserPtr is null)
    {
      /* ERR_NOSUCHNICK */
      kicker.tx401(targetName);
      return;
    }
    kickUsers ~= *targetUserPtr;
  }

  if (kickChans.length != 1 && kickUsers.length != kickChans.length)
  {
    /* ERR_NEEDMOREPARAMS */
    kicker.tx461("KICK");
    /* This should never happen, as the loop in which we fill kickChan and kickUsers should have
     * already bailed out if there was a problem.
     */
    logInfo("  KICK: hmm.. must be a bug processing KICK arguments");
    foreach (iArg, arg; args) logInfo("  arg %d = \"%s\"", iArg, arg);
    foreach (iKickUser, kickUser; kickUsers) logInfo("  kickUser %d = \"%s\"", iKickUser, kickUser.nickUserHost);
    foreach (iKickChan, kickChan; kickChans) logInfo("  kickChan %d = \"%s\"", iKickChan, kickChan.name);
    return;
  }
  if (kickChans.length == 1)
  {
    auto kickChan = kickChans[0];
    auto kickerUcPtr = kickChan.canonicalName in kicker.channels;
    if (kickerUcPtr is null || !kickerUcPtr.joined)
    {
      kicker.tx442(kickChan.name);
      return;
    }
    if (!kickerUcPtr.channelOperator)
    {
      kicker.tx482(kickChan.name);
      return;
    }
    foreach (kickUser; kickUsers)
    {
      kickChan.joinedUsers.txum!"KICK %s %s :%s"(kicker, kickChan.name, kickUser.nick, reason);
      kickUser.channels.remove(kickChan.canonicalName);
      kickChan.users.remove(kickUser.iid);
    }
  }
  else
  {
    foreach (kickChan, kickUser; lockstep(kickChans, kickUsers))
    {
      auto kickerUcPtr = kickChan.canonicalName in kicker.channels;
      if (kickerUcPtr is null || !kickerUcPtr.joined)
      {
        kicker.tx442(kickChan.name);
        continue;
      }
      if (!kickerUcPtr.channelOperator)
      {
        kicker.tx482(kickChan.name);
        continue;
      }
      kickChan.joinedUsers.txsn!"KICK %s %s :%s"(kicker, kickChan.name, kickUser.nick, reason);
      kickUser.channels.remove(kickChan.canonicalName);
      kickChan.users.remove(kickUser.iid);
    }
  }
}
