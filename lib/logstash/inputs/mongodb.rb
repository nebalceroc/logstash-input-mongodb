# encoding: utf-8

require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/timestamp"
require "stud/interval"
require "socket" # for Socket.gethostname
require "json"
require "mongo"

include Mongo

class LogStash::Inputs::MongoDB < LogStash::Inputs::Base
  config_name "mongodb"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

  # Example URI: mongodb://mydb.host:27017/mydbname?ssl=true
  config :uri, :validate => :string, :required => true

  # The directory that will contain the sqlite database file.
  config :placeholder_db_dir, :validate => :string, :required => true

  # The name of the sqlite databse file
  config :placeholder_db_name, :validate => :string, :default => "logstash_sqlite.db"

  # Any table to exclude by name
  config :exclude_tables, :validate => :array, :default => []

  config :batch_size, :validate => :number, :default => 30

  config :since_table, :validate => :string, :default => "logstash_since"

  # This allows you to select the column you would like compare the since info
  config :since_column, :validate => :string, :default => "_id"

  # This allows you to select the type of since info, like "id", "date"
  config :since_type,   :validate => :string, :default => "id"

  # The collection to use. Is turned into a regex so 'events' will match 'events_20150227'
  # Example collection: events_20150227 or events_
  config :collection, :validate => :string, :required => true

  # This allows you to select the method you would like to use to parse your data
  config :parse_method, :validate => :string, :default => 'simple'

  # If not flattening you can dig to flatten select fields
  config :dig_fields, :validate => :array, :default => []

  # This is the second level of hash flattening
  config :dig_dig_fields, :validate => :array, :default => []

  # If true, store the @timestamp field in mongodb as an ISODate type instead
  # of an ISO8601 string.  For more information about this, see
  # http://www.mongodb.org/display/DOCS/Dates
  config :isodate, :validate => :boolean, :default => false

  # Number of seconds to wait after failure before retrying
  config :retry_delay, :validate => :number, :default => 3, :required => false

  # If true, an "_id" field will be added to the document before insertion.
  # The "_id" field will use the timestamp of the event and overwrite an existing
  # "_id" field in the event.
  config :generateId, :validate => :boolean, :default => false

  config :unpack_mongo_id, :validate => :boolean, :default => false

  # The message string to use in the event.
  config :message, :validate => :string, :default => "Default message..."

  # Set how frequently messages should be sent.
  # The default, `1`, means send a message every second.
  config :interval, :validate => :number, :default => 1

  #config :update, :validate => :boolean, :defalut => false

  config :update_time, :validate => :number, :default => 3600, :required => false

  config :mongo_user, :validate => :string, :required => true

  config :mongo_password, :validate => :string, :required => true

  config :update_flag, :validate => :string, :required => true

  config :ls_stamp, :validate => :string, :default => 'ls_stamp'

  config :since_date, :validate => :string, :default => 'default'

  SINCE_TABLE = :since_table

  public
  def init_placeholder_table(sqlitedb)
    begin
      sqlitedb.create_table "#{SINCE_TABLE}" do
        String :table
        String :place
      end
    rescue
      @logger.debug("since table already exists")
    end
  end

  public
  def init_placeholder(sqlitedb, since_table, mongodb, mongo_collection_name)
    @logger.debug("init placeholder for #{since_table}_#{mongo_collection_name}")
    since = sqlitedb[SINCE_TABLE]
    mongo_collection = mongodb.collection(mongo_collection_name)

    #find query
    @logger.info("since date #{since_date}")
    initial_date = Date.strptime(@since_date, '%Y-%m-%d')
    @logger.info("initial_date date #{initial_date}")
    if @collection == "products"
      first_entry = mongo_collection.find({:estado => {:$ne=>"B"}}).sort(since_column => 1).limit(1).first
    else
      first_entry = mongo_collection.find({:visto=>{:$gte=>initial_date},:estado => {:$ne=>"B"}}).sort(since_column => 1).limit(1).first
    end

    first_entry_id = ''
    if since_type == 'id'
      first_entry_id = first_entry[since_column].to_s
    else
      first_entry_id = first_entry[since_column].to_i
    end
    since.insert(:table => "#{since_table}_#{mongo_collection_name}", :place => first_entry_id)
    @logger.info("init placeholder for #{since_table}_#{mongo_collection_name}: #{first_entry}")
    return first_entry_id
  end

  public
  def get_placeholder(sqlitedb, since_table, mongodb, mongo_collection_name)
    since = sqlitedb[SINCE_TABLE]
    x = since.where(:table => "#{since_table}_#{mongo_collection_name}")
    if x[:place].nil? || x[:place] == 0
      first_entry_id = init_placeholder(sqlitedb, since_table, mongodb, mongo_collection_name)
      @logger.debug("FIRST ENTRY ID for #{mongo_collection_name} is #{first_entry_id}")
      return first_entry_id
    else
      @logger.debug("placeholder already exists, it is #{x[:place]}")
      return x[:place][:place]
    end
  end

  public
  def update_placeholder(sqlitedb, since_table, mongo_collection_name, place)
    #@logger.debug("updating placeholder for #{since_table}_#{mongo_collection_name} to #{place}")
    since = sqlitedb[SINCE_TABLE]
    since.where(:table => "#{since_table}_#{mongo_collection_name}").update(:place => place)
  end

  public
  def get_all_tables(mongodb)
    return @mongodb.collection_names
  end

  public
  def get_collection_names(mongodb, collection)
    collection_names = []
    @mongodb.collection_names.each do |coll|
      if /#{collection}/ =~ coll
        collection_names.push(coll)
        @logger.debug("Added #{coll} to the collection list as it matches our collection search")
      end
    end
    return collection_names
  end

  public
  def get_cursor_for_collection(mongodb, mongo_collection_name, last_id_object, batch_size)
    collection = mongodb.collection(mongo_collection_name)
    # Need to make this sort by date in object id then get the first of the series
    # db.events_20150320.find().limit(1).sort({ts:1})
    initial_date = Date.strptime(@since_date, '%Y-%m-%d')
    if @collection == "products"
      return collection.find({:_id => {:$gt => last_id_object},:estado=>{:$ne=>"B"}}).limit(batch_size)
    else
      return collection.find({:_id => {:$gt => last_id_object},:visto=>{:$gte=>initial_date},:estado=>{:$ne=>"B"}}).limit(batch_size)
    end

  end

  public
  def get_updated_documents(mongodb, my_collection)
    doc_list = {}
    #@logger.info("GETTING " + my_collection)
    col = mongodb[my_collection]
    #doc_list = col.find(:visto => {:$gte => start_date,:$lt => end_date})
    doc_list = col.find(@update_flag => true, :estado => {:$ne=>"B"})
    return doc_list
  end

  public
  def burn_those_flags_down(mongodb, my_collection, stamp)
    col = mongodb[my_collection]
    result = col.update_many( {@update_flag => true}, { '$set' => { @update_flag => false }}, {:upsert => false} )
    @logger.info("INPUT_PLUGIN (#{my_collection} #{stamp}) FLAGS DOWN: #{result.modified_count}")
  end

  public
  def send_updated_documents(queue, mongodb, my_collection)
    doc_list = {}
    @logger.info("GETTING " + my_collection)
    col = mongodb[my_collection]
    #doc_list = col.find(:visto => {:$gte => start_date,:$lt => end_date})
    doc_list = col.find(@update_flag => true, :estado => {:$ne=>"B"})
    up_qty = 0

    doc_list.each do |doc|
      up_qty = up_qty + 1
      queue << process_doc(doc)
    end
    @logger.info("INPUT_PLUGIN UP_QTY: #{up_qty}")

    result = col.update_many( {@update_flag => true}, { '$set' => { @update_flag => false }}, {:upsert => false} )
    @logger.info("INPUT_PLUGIN FLAGS DOWN: #{result.modified_count}")
  end

  public
  def update_watched_collections(mongodb, collection, sqlitedb)
    collections = get_collection_names(mongodb, collection)
    collection_data = {}
    collections.each do |my_collection|
      init_placeholder_table(sqlitedb)
      last_id = get_placeholder(sqlitedb, since_table, mongodb, my_collection)
      if !collection_data[my_collection]
        collection_data[my_collection] = { :name => my_collection, :last_id => last_id }
      end
    end
    return collection_data
  end

  public
  def register
    require "jdbc/sqlite3"
    require "sequel"
    placeholder_db_path = File.join(@placeholder_db_dir, @placeholder_db_name)
    #client_options = {
    #  user: @mongo_user,
    #  password: @mongo_password
    #}
    #conn = Mongo::Client.new(@uri,client_options)
    conn = Mongo::Client.new(@uri)

    @host = Socket.gethostname
    @logger.info("Registering MongoDB input")

    @mongodb = conn.database
    @sqlitedb = Sequel.connect("jdbc:sqlite:#{placeholder_db_path}")

    if @since_date == "default"
      now = Date.today
      ninety_days_ago = (now - 90)
      @since_date = ninety_days_ago.strftime("%Y-%m-%d")
    end

    # Should check to see if there are new matching tables at a predefined interval or on some trigger
    @collection_data = update_watched_collections(@mongodb, @collection, @sqlitedb)
    #@last_update = Time.new(2000)
    @last_update = Time.now.getutc
  end # def register

  class BSON::OrderedHash
    def to_h
      inject({}) { |acc, element| k,v = element; acc[k] = (if v.class == BSON::OrderedHash then v.to_h else v end); acc }
    end

    def to_json
      JSON.parse(self.to_h.to_json, :allow_nan => true)
    end
  end

  def flatten(my_hash)
    new_hash = {}
    #@logger.debug("Raw Hash: #{my_hash}")
    if my_hash.respond_to? :each
      my_hash.each do |k1,v1|
        if v1.is_a?(Hash)
          v1.each do |k2,v2|
            if v2.is_a?(Hash)
              # puts "Found a nested hash"
              result = flatten(v2)
              result.each do |k3,v3|
                new_hash[k1.to_s+"_"+k2.to_s+"_"+k3.to_s] = v3
              end
              # puts "result: "+result.to_s+" k2: "+k2.to_s+" v2: "+v2.to_s
            else
              new_hash[k1.to_s+"_"+k2.to_s] = v2
            end
          end
        else
          # puts "Key: "+k1.to_s+" is not a hash"
          new_hash[k1.to_s] = v1
        end
      end
    else
      @logger.debug("Flatten [ERROR]: hash did not respond to :each")
    end
    #@logger.debug("Flattened Hash: #{new_hash}")
    return new_hash
  end

  def process_doc(doc)
    logdate = DateTime.parse(doc['_id'].generation_time.to_s)
    event = LogStash::Event.new("host" => @host)
    decorate(event)
    event.set("logdate",logdate.iso8601.force_encoding(Encoding::UTF_8))
    log_entry = doc.to_h.to_s
    log_entry['_id'] = log_entry['_id'].to_s
    event.set("log_entry",log_entry.force_encoding(Encoding::UTF_8))
    event.set("mongo_id",doc['_id'].to_s)
    @logger.debug("mongo_id: "+doc['_id'].to_s)
    #@logger.debug("EVENT looks like: "+event.to_s)
    #@logger.debug("Sent message: "+doc.to_h.to_s)
    #@logger.debug("EVENT looks like: "+event.to_s)
    # Extract the HOST_ID and PID from the MongoDB BSON::ObjectID
    if @unpack_mongo_id
      doc_hex_bytes = doc['_id'].to_s.each_char.each_slice(2).map {|b| b.join.to_i(16) }
      doc_obj_bin = doc_hex_bytes.pack("C*").unpack("a4 a3 a2 a3")
      host_id = doc_obj_bin[1].unpack("S")
      process_id = doc_obj_bin[2].unpack("S")
      event.set('host_id',host_id.first.to_i)
      event.set('process_id',process_id.first.to_i)
    end

    if @parse_method == 'simple'
      doc.each do |k, v|
          if k == '_id'
            event.set("mongo_id", doc['_id'].to_s)
            next
          end
          if k.include? "@"
            next
          end
          if v.is_a? Numeric
            event.set(k, v.abs)
          elsif v.is_a? Array
            event.set(k, v)
          elsif v.is_a? Hash
            event.set(k, v)
          elsif v == "NaN"
            event.set(k, Float::NAN)
          else
            event.set(k, v.to_s)
          end
      end
    end
    return event
  end

  def run(queue)
    sleep_min = 0.01
    sleep_max = 5
    sleeptime = sleep_min

    @logger.debug("Tailing MongoDB")
    #@logger.debug("Collection data is: #{@collection_data}")

    while true && !stop?
      begin
        @collection_data.each do |index, collection|
          collection_name = collection[:name]
          #@logger.debug("collection_data is: #{@collection_data}")
          @logger.debug("collection_data is: " + collection_name)
          last_id = @collection_data[index][:last_id]
          #@logger.debug("last_id is #{last_id}", :index => index, :collection => collection_name)
          # get batch of events starting at the last_place if it is set

          last_id_object = last_id
          if since_type == 'id'
            last_id_object = BSON::ObjectId(last_id)
          elsif since_type == 'time'
            if last_id != ''
              last_id_object = Time.at(last_id)
            end
          end
          cursor = get_cursor_for_collection(@mongodb, collection_name, last_id_object, batch_size)
          cursor.each do |doc|
            doc[@ls_stamp] = "INIT"
            queue << process_doc(doc)

            since_id = doc[since_column]
            if since_type == 'id'
              since_id = doc[since_column].to_s
            elsif since_type == 'time'
              since_id = doc[since_column].to_i
            end

            @collection_data[index][:last_id] = since_id
          end
          # Store the last-seen doc in the database
          update_placeholder(@sqlitedb, since_table, collection_name, @collection_data[index][:last_id])

          pivot_date = Time.now.getutc

          #Collection documents update check (3600 secs = 1 hour)
          if @last_update.to_i + @update_time.to_i < pivot_date.to_i
            d1 = @last_update.to_s
            d2 = pivot_date.to_s
            logger.info("INPUT_PLUGIN (#{collection_name} #{d2}) UPDATE TRIGGERED:  #{d1} - #{d2}")
            updated_data = get_updated_documents(@mongodb, collection_name)
            #send_updated_documents(queue, @mongodb, collection_name)
            up_qty = 0
            updated_data.each do |doc|
              adoc = doc.dup
              adoc[@ls_stamp] = pivot_date.to_s
              up_qty = up_qty + 1
              queue << process_doc(adoc)
            end
            @logger.info("INPUT_PLUGIN (#{collection_name} #{d2}) UP_QTY: #{up_qty}")
            burn_those_flags_down(@mongodb, collection_name, d2)
            @last_update = pivot_date
          end
        end
        @logger.debug("Updating watch collections")
        @collection_data = update_watched_collections(@mongodb, @collection, @sqlitedb)

        # nothing found in that iteration
        # sleep a bit
        @logger.debug("No new rows. Sleeping.", :time => sleeptime)
        sleeptime = [sleeptime * 2, sleep_max].min
        sleep(sleeptime)
      rescue => e
        @logger.warn('MongoDB Input threw an exception, restarting', :exception => e)
      end
    end
  end # def run

  def close
    # If needed, use this to tidy up on shutdown
    @logger.debug("Shutting down...")
  end

end # class LogStash::Inputs::Example
