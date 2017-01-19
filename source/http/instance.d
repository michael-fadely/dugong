module http.instance;

public import std.socket;

import core.time;

import std.algorithm;
import std.array;
import std.concurrency;
import std.conv;
import std.exception;
import std.range;
import std.string;
import std.uni : sicmp;

import http.common;
import http.enums;
import http.response;

/// Interface for HTTP instances.
interface IHttpInstance
{
	/// Returns the connected state of this instance.
	@property bool connected();
	/// Disconnects this instance.
	void disconnect();
	/// Main parsing routine.
	void run();
	/// Main receiving function.
	/// Returns: $(D true) if data has been received.
	bool receive();
	/// Sends the data stored in this instance to the given socket.
	void send(Socket s);
	/// Sends the data in this instance to its connected socket.
	void send();
	/// Clears the data in this instance.
	void clear();
}

/// Base class for $(D HttpRequest) and $(D HttpResponse).
abstract class HttpInstance : IHttpInstance
{
private:
	bool persistent;
	bool hasBody_;
	bool chunked;

protected:
	Socket socket;

	Appender!(char[]) overflow;
	HttpVersion version_;
	string[string] headers;
	ubyte[] body_;

public:
	this(Socket socket, bool hasBody = true, lazy Duration timeout = 5.seconds)
	{
		enforce(socket !is null, "socket must not be null!");
		enforce(socket.isAlive, "socket must be connected!");

		this.socket = socket;
		this.hasBody_ = hasBody;
		this.socket.blocking = false;
		this.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, timeout);
		this.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, timeout);
	}

	void disconnect()
	{
		socket.disconnect();
		socket = null;
		clear();
	}

	void clear()
	{
		overflow.clear();

		persistent = false;
		version_   = HttpVersion.v1_1;
		headers    = null;
		body_      = null;
		chunked    = false;
	}

	void send(Socket s)
	{
		auto str = toString();

		if (hasBody && body_.empty)
		{
			s.send(str);

			if (isChunked)
			{
				foreach (buffer; getChunks())
				{
					s.send(buffer);
				}
			}
		}
		else
		{
			s.send(cast(ubyte[])str ~ body_);
		}
	}

	void send()
	{
		send(socket);
	}

final:
	@property bool isPersistent() { return persistent; }
	@property bool hasBody() { return hasBody_; }
	@property bool isChunked() { return chunked; }
	@property bool connected()
	{
		return socket !is null && socket.isAlive;
	}

	string getHeader(in string key, string* realKey = null)
	{
		import std.uni : sicmp;

		auto ptr = key in headers;
		if (ptr !is null)
		{
			return *ptr;
		}

		auto search = headers.byPair.find!(x => !sicmp(key, x[0]));

		if (!search.empty)
		{
			auto result = takeOne(search);

			if (realKey !is null)
			{
				*realKey = result.front[0];
			}

			return result.front[1];
		}

		return null;
	}

	/// Reads available headers from the socket and populates
	/// $(D headers), performs error handling, maybe more idk.
	void parseHeaders()
	{
		ptrdiff_t rlength = -1;
		for (char[] header; (rlength = socket.readln(overflow, header)) > 0 && !header.empty;)
		{
			auto key = header.munch("^:").idup;
			header.munch(": ");

			// Skip duplicate Content-Length headers.
			if (!sicmp(key, "Content-Length") && !getHeader(key).empty)
			{
				continue;
			}

			headers[key] = header.idup;
		}

		string key;
		auto contentLength = getHeader("Content-Length", &key);
		chunked = !getHeader("Transfer-Encoding").empty;

		if (!contentLength.empty)
		{
			if (chunked)
			{
				enforce(headers.remove(key));
			}
			else if (hasBody)
			{
				rlength = socket.readlen(overflow, body_, to!size_t(contentLength));
			}
		}

		auto connection = getHeader("Connection");
		if (connection.empty)
		{
			connection = getHeader("Proxy-Connection");
		}

		switch (version_) with (HttpVersion)
		{
			case v1_0:
				persistent = !sicmp(connection, "keep-alive");
				break;

			case v1_1:
				persistent = !!sicmp(connection, "close");
				break;

			default:
				if (socket.isAlive)
				{
					socket.sendResponse(HttpStatus.httpVersionNotSupported);
				}

				disconnect();
				return;
		}

		if (!rlength)
		{
			disconnect();
		}
	}

	/// Converts the key-value pairs in $(D headers) to a string.
	string toHeaderString() const
	{
		if (!headers.length)
		{
			return null;
		}

		return headers.byKeyValue.map!(x => x.key ~ ": " ~ x.value).join("\r\n");
	}

	Generator!(ubyte[]) getChunks()
	{
		enforce(isChunked, "getChunks() called on response with no chunked data.");

		return new Generator!(ubyte[])(
		{
			// readChunk yields the buffer whenever possible
			if (!socket.readChunk(overflow, body_))
			{
				disconnect();
			}
		});
	}
}
