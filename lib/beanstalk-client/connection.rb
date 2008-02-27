# beanstalk-client/connection.rb - client library for beanstalk

# Copyright (C) 2007 Philotic Inc.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'socket'
require 'fcntl'
require 'yaml'
require 'beanstalk-client/bag'
require 'beanstalk-client/errors'
require 'beanstalk-client/job'

module Beanstalk
  class RawConnection
    attr_reader :addr

    def initialize(addr, jptr=self)
      @addr = addr
      @jptr = jptr
      connect
    end

    def connect
      host, port = addr.split(':')
      @socket = TCPSocket.new(host, port.to_i)

      # Don't leak fds when we exec.
      @socket.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
    end

    def close
      @socket.close
      @socket = nil
    end

    def put(body, pri=65536, delay=0, ttr=120)
      @socket.write("put #{pri} #{delay} #{ttr} #{body.size}\r\n#{body}\r\n")
      check_resp('INSERTED', 'BURIED')[0].to_i
    end

    def yput(obj, pri=65536, delay=0, ttr=120)
      put(YAML.dump(obj), pri, delay, ttr)
    end

    def peek()
      @socket.write("peek\r\n")
      begin
        Job.new(@jptr, *read_job('FOUND'))
      rescue UnexpectedResponse
        nil
      end
    end

    def peek_job(id)
      @socket.write("peek #{id}\r\n")
      Job.new(@jptr, *read_job('FOUND'))
    end

    def reserve()
      @socket.write("reserve\r\n")
      Job.new(@jptr, *read_job('RESERVED'))
    end

    def delete(id)
      @socket.write("delete #{id}\r\n")
      check_resp('DELETED')
      :ok
    end

    def release(id, pri, delay)
      @socket.write("release #{id} #{pri} #{delay}\r\n")
      check_resp('RELEASED')
      :ok
    end

    def bury(id, pri)
      @socket.write("bury #{id} #{pri}\r\n")
      check_resp('BURIED')
      :ok
    end

    def use(tube)
      @socket.write("use #{tube}\r\n")
      check_resp('USING')[0]
    end

    def watch(tube)
      @socket.write("watch #{tube}\r\n")
      check_resp('WATCHING')[0]
    end

    def ignore(tube)
      @socket.write("ignore #{tube}\r\n")
      check_resp('WATCHING')[0]
    end

    def stats()
      @socket.write("stats\r\n")
      read_yaml('OK')
    end

    def job_stats(id)
      @socket.write("stats-job #{id}\r\n")
      read_yaml('OK')
    end

    private

    def get_resp()
      r = @socket.gets("\r\n")
      raise EOFError if r == nil
      r[0...-2]
    end

    def check_resp(*words)
      r = get_resp()
      rword, *vals = r.split(/\s+/)
      if (words.size > 0) and !words.include?(rword)
        raise UnexpectedResponse.new(r)
      end
      vals
    end

    def read_job(word)
      # Give the user a chance to select on multiple fds.
      Beanstalk.select.call([@socket]) if Beanstalk.select

      id, bytes = check_resp(word).map{|s| s.to_i}
      body = read_bytes(bytes)
      raise 'bad trailer' if read_bytes(2) != "\r\n"
      [id, body]
    end

    def read_yaml(word)
      bytes_s, = check_resp(word)
      yaml = read_bytes(bytes_s.to_i)
      raise 'bad trailer' if read_bytes(2) != "\r\n"
      YAML::load(yaml)
    end

    def read_bytes(n)
      str = @socket.read(n)
      raise EOFError, 'End of file reached' if str == nil
      raise EOFError, 'End of file reached' if str.size < n
      str
    end
  end

  # Same interface as RawConnection.
  # With this you can reserve more than one job at a time.
  class Connection
    attr_reader :addr

    def initialize(addr, jptr=self)
      @addr = addr
      @misc = RawConnection.new(addr, jptr)
      @free = Bag.new{RawConnection.new(addr, jptr)}
      @used = {}
    end

    def reserve()
      c = @free.take()
      j = c.reserve()
      @used[j.id] = c
      j
    ensure
      @free.give(c) if c and not j
    end

    def delete(id)
      @used[id].delete(id)
      @free.give(@used.delete(id))
    end

    def release(id, pri, delay)
      @used[id].release(id, pri, delay)
      @free.give(@used.delete(id))
    end

    def bury(id, pri)
      @used[id].bury(id, pri)
      @free.give(@used.delete(id))
    end

    def method_missing(selector, *args, &block)
      @misc.send(selector, *args, &block)
    end
  end

  class CleanupWrapper
    def initialize(addr, multi)
      @conn = Connection.new(addr, self)
      @multi = multi
    end

    def method_missing(selector, *args, &block)
      begin
        @conn.send(selector, *args, &block)
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, UnexpectedResponse => ex
        @multi.remove(@conn)
        raise ex
      end
    end
  end

  class Pool
    def initialize(addrs)
      @addrs = addrs
      connect()
    end

    def connect()
      @connections ||= {}
      @addrs.each do |addr|
        begin
          if !@connections.include?(addr)
            puts "connecting to beanstalk at #{addr}"
            @connections[addr] = CleanupWrapper.new(addr, self)
          end
        rescue Exception => ex
          puts "#{ex.class}: #{ex}"
          #puts begin ex.fixed_backtrace rescue ex.backtrace end
        end
      end
      @connections.size
    end

    def open_connections()
      @connections.values()
    end

    def last_server
      @last_conn.addr
    end

    def send_to_rand_conn(sel, *args)
      wrap(pick_connection, sel, *args)
    end

    def send_to_all_conns(sel, *args)
      make_hash(@connections.map{|a, c| [a, wrap(c, sel, *args)]})
    end

    def put(body, pri=65536, delay=0, ttr=120)
      send_to_rand_conn(:put, body, pri, delay, ttr)
    end

    def yput(obj, pri=65536, delay=0, ttr=120)
      send_to_rand_conn(:yput, obj, pri, delay, ttr)
    end

    def reserve()
      send_to_rand_conn(:reserve)
    end

    def use(tube)
      send_to_all_conns(:use, tube)
    end

    def watch(tube)
      send_to_all_conns(:watch, tube)
    end

    def ignore(tube)
      send_to_all_conns(:ignore, tube)
    end

    def raw_stats()
      send_to_all_conns(:stats)
    end

    def stats()
      raw_stats.values.inject({}){|a,b| a.merge(b) {|k,o,n| o + n}}
    end

    def remove(conn)
      @connections.delete(conn.addr)
    end

    def close
      while @connections.size > 0
        addr, conn = @connections.pop
        conn.close
      end
    end

    def peek()
      open_connections.each do |c|
        job = c.peek
        return job if job
      end
      nil
    end

    private

    def pick_connection()
      open_connections[rand(open_connections.size)] or raise NotConnected
    end

    def wrap(conn, sel, *args)
      (@last_conn = conn).send(sel, *args)
    rescue DrainingError
      # Don't reconnect -- we're not interested in this server
      retry
    rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
      connect()
      retry
    end

    def make_hash(pairs)
      Hash[*pairs.inject([]){|a,b|a+b}]
    end
  end
end
