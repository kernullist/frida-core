namespace Zed.Service {
	public class FruityHostSessionBackend : Object, HostSessionBackend {
		private Fruity.Client control_client;
		private Gee.HashMap<uint, FruityHostSessionProvider> provider_by_device_id = new Gee.HashMap<uint, FruityHostSessionProvider> ();

		public async void start () {
			control_client = new Fruity.Client ();
			control_client.device_connected.connect ((device_id, device_udid) => {
				if (provider_by_device_id.has_key (device_id))
					return;

				var provider = new FruityHostSessionProvider (device_id, device_udid);
				provider_by_device_id[device_id] = provider;
				open_provider (provider);
			});
			control_client.device_disconnected.connect ((device_id) => {
				if (!provider_by_device_id.has_key (device_id))
					return;

				FruityHostSessionProvider provider;
				provider_by_device_id.unset (device_id, out provider);
				provider_unavailable (provider);
			});

			try {
				yield control_client.establish ();
				yield control_client.enable_monitor_mode ();
			} catch (Error e) {
				debug ("failed to establish: %s", e.message);
			}
		}

		public async void stop () {
			try {
				yield control_client.close ();
			} catch (IOError e) {
			}
			control_client = null;

			foreach (var provider in provider_by_device_id.values) {
				provider_unavailable (provider);
				yield provider.close ();
			}
			provider_by_device_id.clear ();
		}

		private async void open_provider (FruityHostSessionProvider provider) {
			try {
				yield provider.open ();

				provider_available (provider);
			} catch (IOError e) {
				provider_by_device_id.unset (provider.device_id);
			}
		}
	}

	public class FruityHostSessionProvider : Object, HostSessionProvider {
		public string name {
			get { return _name; }
		}
		private string _name = "Apple Mobile Device";

		public ImageData? icon {
			get { return _icon; }
		}
		private ImageData? _icon = null;

		public HostSessionProviderKind kind {
			get { return HostSessionProviderKind.LOCAL_TETHER; }
		}

		public uint device_id {
			get;
			construct;
		}

		public string device_udid {
			get;
			construct;
		}

		private Gee.ArrayList<Entry> entries = new Gee.ArrayList<Entry> ();

		private const uint ZID_SERVER_PORT = 27042;

		public FruityHostSessionProvider (uint device_id, string device_udid) {
			Object (device_id: device_id, device_udid: device_udid);
		}

		construct {
		}

		public async void open () throws IOError {
			bool got_details = false;
			for (int i = 0; !got_details; i++) {
				try {
					_extract_details_for_device_with_udid (device_udid, out _name, out _icon);
					got_details = true;
				} catch (IOError e) {
					if (i != 60 - 1) {
						Timeout.add (1000, () => {
							open.callback ();
							return false;
						});
						yield;
					} else {
						break;
					}
				}
			}

			if (!got_details)
				throw new IOError.TIMED_OUT ("timed out");
		}

		public async void close () {
			foreach (var entry in entries) {
				try {
					yield entry.connection.close ();
				} catch (IOError first_close_error) {
				}

				/* FIXME: close again to make sure things are shut down, needs further investigation */
				try {
					yield entry.connection.close ();
				} catch (IOError second_close_error) {
				}

				try {
					yield entry.client.close ();
				} catch (IOError client_error) {
				}
			}
			entries.clear ();
		}

		public async HostSession create () throws IOError {
			var client = new Fruity.Client ();
			yield client.establish ();
			yield client.connect_to_port (device_id, ZID_SERVER_PORT);

			DBusConnection connection;
			try {
				connection = yield DBusConnection.new_for_stream (client.connection, null, DBusConnectionFlags.AUTHENTICATION_CLIENT);
			} catch (Error e) {
				throw new IOError.FAILED (e.message);
			}

			HostSession session = connection.get_proxy_sync (null, ObjectPath.HOST_SESSION);

			var entry = new Entry (0, client, connection, session);
			entries.add (entry);

			connection.closed.connect (on_connection_closed);

			return session;
		}

		public async AgentSession obtain_agent_session (AgentSessionId id) throws IOError {
			Fruity.Client client = null;

			bool connected = false;
			for (int i = 0; !connected; i++) {
				client = new Fruity.Client ();
				yield client.establish ();

				try {
					yield client.connect_to_port (device_id, id.handle);
					connected = true;
				} catch (IOError client_error) {
					if (i != 10 - 1) {
						Timeout.add (200, () => {
							obtain_agent_session.callback ();
							return false;
						});
						yield;
					} else {
						break;
					}
				}
			}

			if (!connected)
				throw new IOError.TIMED_OUT ("timed out");

			DBusConnection connection;
			try {
				connection = yield DBusConnection.new_for_stream (client.connection, null, DBusConnectionFlags.AUTHENTICATION_CLIENT);
			} catch (Error dbus_error) {
				throw new IOError.FAILED (dbus_error.message);
			}

			AgentSession session = connection.get_proxy_sync (null, ObjectPath.AGENT_SESSION);

			var entry = new Entry (id.handle, client, connection, session);
			entries.add (entry);

			connection.closed.connect (on_connection_closed);

			return session;
		}

		public static extern void _extract_details_for_device_with_udid (string udid, out string name, out ImageData? icon) throws IOError;

		private void on_connection_closed (DBusConnection connection, bool remote_peer_vanished, GLib.Error? error) {
			bool closed_by_us = (!remote_peer_vanished && error == null);
			if (closed_by_us)
				return;

			Entry entry_to_remove = null;
			foreach (var entry in entries) {
				if (entry.connection == connection) {
					entry_to_remove = entry;
					break;
				}
			}
			assert (entry_to_remove != null);

			entries.remove (entry_to_remove);

			if (entry_to_remove.id != 0) /* otherwise it's a HostSession */
				agent_session_closed (AgentSessionId (entry_to_remove.id), error);
		}

		private class Entry : Object {
			public uint id {
				get;
				private set;
			}

			public Fruity.Client client {
				get;
				private set;
			}

			public DBusConnection connection {
				get;
				private set;
			}

			public Object proxy {
				get;
				private set;
			}

			public Entry (uint id, Fruity.Client client, DBusConnection connection, Object proxy) {
				this.id = id;
				this.client = client;
				this.connection = connection;
				this.proxy = proxy;
			}
		}
	}

	namespace Fruity {
		public class Client : Object {
			public SocketConnection connection {
				get;
				private set;
			}
			private InputStream input;
			private OutputStream output;

			private bool running;
			private uint last_tag;
			private uint mode_switch_tag;
			private Gee.ArrayList<PendingResponse> pending_responses;

			private const uint16 USBMUX_SERVER_PORT = 27015;

			public signal void device_connected (uint device_id, string device_udid);
			public signal void device_disconnected (uint device_id);

			public Client () {
				reset ();
			}

			private void reset () {
				connection = null;
				input = null;
				output = null;

				running = false;
				last_tag = 1;
				mode_switch_tag = 0;
				pending_responses = new Gee.ArrayList<PendingResponse> ();
			}

			public async void establish () throws IOError {
				assert (!running);

				var client = new SocketClient ();

				try {
					connection = yield client.connect_to_host_async ("127.0.0.1", USBMUX_SERVER_PORT);
					input = connection.get_input_stream ();
					output = connection.get_output_stream ();

					running = true;

					process_incoming_messages ();
				} catch (Error e) {
					reset ();
					throw new IOError.FAILED (e.message);
				}
			}

			public async void close () throws IOError {
				if (!running)
					throw new IOError.FAILED ("not running");
				running = false;

				try {
					var conn = this.connection;
					yield conn.close_async (Priority.DEFAULT);
				} catch (Error e) {
				}
				connection = null;
				input = null;
				output = null;
			}

			public async void enable_monitor_mode () throws Error {
				assert (running);

				var result = yield send_request_and_receive_response (MessageType.HELLO);
				if (result != ResultCode.SUCCESS)
					throw new IOError.FAILED ("handshake failed, result %d", result);
			}

			public async void connect_to_port (uint device_id, uint port) throws IOError {
				assert (running);

				uint8[] connect_body = new uint8[8];

				uint32 * p = (void *) connect_body;
				p[0] = device_id.to_little_endian ();
				p[1] = ((uint32) port << 16).to_big_endian ();

				try {
					int result = yield send_request_and_receive_response (MessageType.CONNECT, connect_body, true);
					switch (result) {
						case ResultCode.SUCCESS:
							break;
						case ResultCode.CONNECTION_REFUSED:
							throw new IOError.FAILED ("connect failed (connection refused)");
						case ResultCode.INVALID_REQUEST:
							throw new IOError.FAILED ("connect failed (invalid request)");
						default:
							throw new IOError.FAILED ("connect failed (error code: %d)", result);
					}
				} catch (Error e) {
					throw new IOError.FAILED (e.message);
				}
			}

			private async int send_request_and_receive_response (MessageType type, uint8[]? body = null, bool is_mode_switch_request = false) throws Error {
				uint32 tag = last_tag++;

				if (is_mode_switch_request)
					mode_switch_tag = tag;

				var request = create_message (type, tag, body);
				var pending = new PendingResponse (tag, () => send_request_and_receive_response.callback ());
				pending_responses.add (pending);
				yield write_message (request);
				yield;

				return pending.result;
			}

			private async void process_incoming_messages () {
				while (running) {
					try {
						var message_blob = yield read_message ();

						uint32 * header = (void *) message_blob;
						MessageType type = (MessageType) uint.from_little_endian (header[0]);
						uint32 tag = uint.from_little_endian (header[1]);

						uint32 body_size = message_blob.length - 8;
						uint8 * body = (uint8 *) header + 8;
						int32 * body_i32 = (int32 *) body;
						uint32 * body_u32 = (uint32 *) body;

						switch (type) {
							case MessageType.RESULT:
								if (body_size != 4)
									throw new IOError.FAILED ("unexpected payload size for RESULT");
								int result = body_i32[0];

								PendingResponse match = null;
								foreach (var pending in pending_responses) {
									if (pending.tag == tag) {
										match = pending;
										break;
									}
								}

								if (match == null)
									throw new IOError.FAILED ("response to unknown tag");
								pending_responses.remove (match);
								match.complete (result);

								if (tag == mode_switch_tag) {
									if (result == ResultCode.SUCCESS)
										return;
									else
										mode_switch_tag = 0;
								}

								break;

							case MessageType.DEVICE_CONNECTED:
								if (body_size < 4)
									throw new IOError.FAILED ("unexpected payload size for CONNECTED");
								uint conn_device_id = body_u32[0];
								unowned string conn_device_udid = (string) (body + 6);
								device_connected (conn_device_id, conn_device_udid);
								break;

							case MessageType.DEVICE_DISCONNECTED:
								if (body_size != 4)
									throw new IOError.FAILED ("unexpected payload size for DISCONNECTED");
								uint disc_device_id = body_u32[0];
								device_disconnected (disc_device_id);
								break;

							default:
								throw new IOError.FAILED ("unexpected message type: %u", (uint) type);
						}

					} catch (Error e) {
						reset ();
					}
				}
			}

			private async uint8[] read_message () throws Error {
				uint32[] u32_buf = new uint32[1];
				ssize_t len;

				/* total size */
				len = yield input.read_async (u32_buf, 4);
				if (len != 4)
					throw new IOError.FAILED ("short read of size (len = %d)", (int) len);

				uint size = uint.from_little_endian (u32_buf[0]);
				if (size < 16 || size > 1024)
					throw new IOError.FAILED ("protocol error: invalid size");

				/* ignore the next 4 bytes (reserved) */
				len = yield input.read_async (u32_buf, 4);
				if (len != 4)
					throw new IOError.FAILED ("short read of reserved");

				/* body */
				uint body_size = size - 8;
				uint8[] body_buf = new uint8[body_size];
				len = yield input.read_async (body_buf, body_size);
				if (len != body_size)
					throw new IOError.FAILED ("short read of body");
				return body_buf;
			}

			private async void write_message (uint8[] blob) throws Error {
				var len = yield output.write_async (blob, blob.length);
				if (len != blob.length)
					throw new IOError.FAILED ("short write");
			}

			private uint8[] create_message (MessageType type, uint32 tag, uint8[]? body = null) {
				uint body_size = 0;
				if (body != null)
					body_size = body.length;

				uint8[] blob = new uint8[16 + body_size];

				uint32 * p = (void *) blob;
				p[0] = blob.length;
				p[1] = 0;
				p[2] = ((uint) type).to_little_endian ();
				p[3] = tag.to_little_endian ();

				if (body_size != 0) {
					uint8 * blob_start = (void *) blob;
					Memory.copy (blob_start + 16, body, body_size);
				}

				return blob;
			}

			private class PendingResponse {
				public uint32 tag {
					get;
					private set;
				}

				public delegate void CompletionHandler ();
				private CompletionHandler handler;

				public int result {
					get;
					private set;
				}

				public PendingResponse (uint32 tag, CompletionHandler handler) {
					this.tag = tag;
					this.handler = handler;
				}

				public void complete (int result) {
					this.result = result;
					handler ();
				}
			}
		}

		private enum MessageType {
			RESULT		    = 1,
			CONNECT		    = 2,
			HELLO		    = 3,
			DEVICE_CONNECTED    = 4,
			DEVICE_DISCONNECTED = 5
		}

		private enum ResultCode {
			SUCCESS		    = 0,
			CONNECTION_REFUSED  = 3,
			INVALID_REQUEST	    = 5
		}
	}
}

