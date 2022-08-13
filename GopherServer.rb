
require "socket"

class NoGophermapError < RuntimeError
  def initialize msg = "Internal error of the server. No gopher map was found."
    super msg
  end
end

class RescourceNotFoundError < RuntimeError
  def initialize msg = "Rescource could not be found. (compare HTTP 404 or Gemini 51)"
    super msg
  end
end

class NoEntryInGophermapError < RuntimeError
  def initialize msg = "The requested resource exists, but it is not present in the gopher map. Therefore, no file type could be determined. The request is aborted."
    super msg
  end
end

class BadRequestError < RuntimeError
  def initialize msg = "The request line was not understood by the server. The request is aborted.  (compare HTTP 400 or Gemini 59)"
    super msg
  end
end

class PathInjectionError < RuntimeError
  def initialize msg = "The server has had a path injection perceived. The request is aborted."
    super msg
  end
end

# A gopher server
#
# @example

class GopherServer
  
  # Parses and returns a gopher map
  #
  # @param map_cnt [String] A gophermap
  # @return [Array] All entries of the gophermap in Ruby readable format
  # @example
  #   GopherServer.parse_gophermap(<<MAP)
  #   iHello to my gopher server!	(NULL)	(NULL)	0
  #   1About me	/me	127.0.0.1	7071
  #   0About me 2	/me_txt	127.0.0.1	7071
  #   9Just a test binary file	/bin	127.0.0.1	7071
  #   MAP
  #   =>
  #     [{:type=>:ti,
  #     :description=>"Hello to my gopher server!",
  #     :selector=>"(NULL)",
  #     :host=>"(NULL)",
  #     :port=>"0"},
  #    {:type=>:t1,
  #     :description=>"About me",
  #     :selector=>"/me",
  #     :host=>"127.0.0.1",
  #     :port=>"7071"},
  #    {:type=>:t0,
  #     :description=>"About me 2",
  #     :selector=>"/me_txt",
  #     :host=>"127.0.0.1",
  #     :port=>"7071"},
  #    {:type=>:t9,
  #     :description=>"Just a test binary file",
  #     :selector=>"/bin",
  #     :host=>"127.0.0.1",
  #     :port=>"7071"}]
  def self.parse_gophermap map_cnt
    map = []
    map_cnt.lines { |line|
      line.chomp!
      entry = {}
      parts = line.split("\t")
      entry[:type] = "t#{parts[0][0]}".to_sym
      entry[:description] = parts[0][1..-1]
      entry[:selector] = parts[1]
      entry[:host] = parts[2]
      entry[:port] = parts[3]
      map << entry
    }
    return map
  end
  
  # Creates a Gopher server. A file named "gophermap" in the typical Gopher format
  # is expected in each directory. This file should contain all available files.
  # So it is determined later whether it is a binary file. If a file is not in
  # the gophermap, it cannot be accessed.
  #
  # @param root_dir [String] The directory from which the files should be delivered.
  # @param hosts [Array] An array containing all aliases of the server which are
  #   also used in the gophermap. If the server is not addressed via one of these
  #   aliases, the link is not recognized in the gopher map, which means that it is
  #   not possible to determine whether a file is binary, which means that the file
  #   cannot be accessed.
  # @param host [String] Host of the gopher server
  # @param port [String] Port of the gopher server
  # @example Creates a server that listens on port 7071 on every address of the computer and delivers the contents of /home/user/gopher/.
  #   serv = GopherServer.new "/home/user/gopher/", ["127.0.0.1", "localhost", "::1"], "::", 7071
  #   serv.listen
  def initialize root_dir, hosts, host = "::", port = 70
    @root_dir = root_dir
    if ! Dir.exist? @root_dir
      raise RuntimeError, "Root directory (#{@root_dir}) does not exist."
    end
    @dir = Dir.new @root_dir
    @host = host
    @hosts = hosts
    @port = port
    @maps_cache = {}
    @request_type_cache = {}
  end
  
  # Starts the server. This command blocks.
  def listen
    serv = TCPServer.new @host, @port
    loop do
      begin
        Thread.new(serv.accept) { |conn|
          handle_connection conn
        }
      rescue
        puts "Unknown error: #{$!}"
      end
    end
  end
  
  # Internal function. Returns the gopher map to a path.
  # 
  # @param mappath [String] Path to the gophermap
  def get_gophermap mappath
    if ! @maps_cache[mappath]
      @maps_cache[mappath] = GopherServer.parse_gophermap File.read(mappath)
    end
    
    return @maps_cache[mappath]
  end
  
  # Internal function. Used to determine whether a file is binary.
  # 
  # @param map [String] Path to the gopher map, which is looked up if not known.
  # @param request [String] File for which it is to be determined whether it is binear.
  def detect_binary map, request
    if ! @request_type_cache[request]
      map = get_gophermap gophermap
      entry = map.detect { |entry|
        @hosts.include?(entry[:host]) && entry[:port] == @port.to_s && entry[:selector] == request
      }
      if entry == nil
        raise NoEntryInGophermapError
      end
      @request_type_cache[request] = entry[:type] == :t5 || entry[:type] == :t9  # rfc1436 3.8
    end
    
    return @request_type_cache[request]
  end
  
  protected
  
  # Internal function. Called to process a connection, i.e. to respond to a gopher request.
  # @param conn [TCPSocket] The connection to the client
  def handle_connection conn
    begin
      request_line = conn.gets
      
      # check for bad request, e. g. invalid request line
      if request_line == nil
        raise BadRequestError
      end
      
      # remove line endings
      request_line.chomp!
      
      # convert request_line to request
      if request_line == ""
        request = "/"
      else
        request = request_line
      end
      
      # Log request
      puts "Request: #{request}"
      
      # Detect path
      path = File.absolute_path "#{@root_dir}/#{request}"
      
      # Avoid path injection, e. g. ../../etc/passwd
      if ! path.start_with? @root_dir
        raise PathInjectionError
      end
      
      # Looking for gopher map
      if File.directory? path
        path_type = :dir
        gophermap = "#{path}/gophermap"
      elsif File.file?(path) && File.readable?(path)
        path_type = :file
        gophermap = "#{File.dirname path}/gophermap"
      else
        raise RescourceNotFoundError
      end
      
      if ! File.readable? gophermap
        raise NoGophermapError
      end
      # Generate unique gophermap address for cache improving (e. g. remove a double slash)
      gophermap = File.realpath(gophermap)
      
      case path_type
      when :dir
        # read file (gophermap) and redirect it to client
        handle_file_request conn, gophermap, false
      when :file
        # read gophermap and detect binary file
        binary = detect_binary gophermap, request
        # read file and redirect it to client
        handle_file_request conn, path, binary
      end
      
      conn.close
    rescue NoEntryInGophermapError, RescourceNotFoundError, NoGophermapError, BadRequestError
      # output error in gemini format
      conn.puts "i#{$!}\t\tinvalid\t0"
      conn.puts "."
      conn.close
    rescue PathInjectionError
      # maybe evil attack, close connection
      conn.close
    rescue
      # log unknown error
      puts "Unknown error: #{$!}"
    end
  end
  
  # Internal function. Outputs a file to the client and, if necessary (if binary is true), a line with a dot.
  #
  # @param conn [TCPSocket] The connection to the client
  # @param file [String] The file path
  # @param binary [TrueClass, FalseClass] True if the file is binary, otherwise false
  def handle_file_request conn, file, binary
    fil = File.new file, "r#{binary ? "b" : nil}"
    IO::copy_stream fil, conn
    fil.close
    conn.puts "." if ! binary
  end
  
end