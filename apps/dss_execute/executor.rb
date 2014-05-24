require 'rubygems'
require 'sequel'
require 'jdbc/dss'

module GoodData::Bricks
  class DssExecutor
    def initialize(params)
      if (!params["dss_GDC_USERNAME"]) || (!params["dss_GDC_PASSWORD"])
        # use the standard ones
        params["dss_GDC_USERNAME"] = params["GDC_USERNAME"]
        params["dss_GDC_PASSWORD"] = params["GDC_PASSWORD"]
      end
      @params = params
      @logger = @params["GDC_LOGGER"]


      Jdbc::DSS.load_driver
      Java.com.gooddata.dss.jdbc.driver.DssDriver
    end

    # expecting hash:
    # table name ->
    #   :fields -> list of columns
    def create_tables(table_hash)
      # create the tables one by one
      table_hash.each do |table, table_meta|
        sql = get_create_sql(table, table_meta[:fields])
        execute(sql)
      end
    end

    # expecting hash:
    # table name ->
    #   :fields -> list of columns
    #   :filename -> name of the csv file
    def load_data(downloaded_info)

      # save the info and load the tables
      load_id = save_download_info(downloaded_info)

      table_hash = downloaded_info[:objects]

      # load the data for each table and each file to be loaded there
      table_hash.each do |table, table_meta|
        table_meta[:filenames].each do |filename|
          sql = get_upload_sql(table, table_meta[:fields], filename, load_id)
          execute(sql)

          # if there's something in the reject/except, raise an error
          if File.size?(get_except_filename(filename)) || File.size?(get_reject_filename(filename))
            raise "Some of the records were rejected: see #{filename}"
          end
        end
      end
    end

    # .each{|t| puts "DROP TABLE dss_#{t};"}

    LOAD_INFO_TABLE_NAME = 'meta_loads'

    # save the info about the download
    # return the load id
    def save_download_info(downloaded_info)
      # generate load id
      load_id = Time.now.to_i

      # create the load table if it doesn't exist yet
      create_sql = get_create_sql(LOAD_INFO_TABLE_NAME, [{:name => 'Salesforce_Server'}])
      execute(create_sql)

      # insert it there
      insert_sql = get_insert_sql(
        sql_table_name(LOAD_INFO_TABLE_NAME),
        {
          "Salesforce_Server" => downloaded_info[:salesforce_server],
          "_LOAD_ID" => load_id
        }
      )
      execute(insert_sql)
      return load_id
    end

    DIRNAME = "tmp"

    # extracts data to be filled in to datasets,
    # writes them to a csv file
    def extract_data(datasets)
      # create the directory if it doesn't exist
      Dir.mkdir(DIRNAME) if ! File.directory?(DIRNAME)

      # extract load info and put it my own params
      @params[:salesforce_downloaded_info] = get_load_info

      # extract each dataset from vertica
      datasets.each do |dataset, ds_structure|

        # if custom sql given
        if ds_structure["extract_sql"]
          # get the sql from the file
          sql = File.open(ds_structure["extract_sql"], 'rb') { |f| f.read }
          columns_gd = nil
        else
          # get the columns and generate the sql
          columns = get_columns(ds_structure)
          columns_gd = columns[:gd]
          sql = get_extract_sql(
            ds_structure["source_table"],
            columns[:sql]
          )
        end

        name = "tmp/#{dataset}-#{DateTime.now.to_i.to_s}.csv"

        # columns of the sql query result
        sql_columns = nil

        # open a file to write select results to it
        CSV.open(name, 'w', :force_quotes => true) do |csv|

          fetch_handler = lambda do |f|
            sql_columns = f.columns
            # write the columns to the csv file as a header
            csv << sql_columns
          end

          # execute the select and write row by row
          execute_select(sql, fetch_handler) do |row|
            row_array = sql_columns.map {|col| row[col]}
            csv << row_array
          end

          if columns_gd && (sql_columns != columns_gd.map {|c| c.to_sym})
            raise "something is weird, the columns of the sql '#{sql_columns}' aren't the same as the given cols '#{columns_gd}' "
          end
        end

        absolute_path = File.absolute_path(name)
        ds_structure["csv_filename"] = absolute_path
        @logger.info("Written results to file #{absolute_path}") if @logger
      end
      return datasets
    end

    def table_has_column(table, column)
      count = nil
      execute_select("SELECT COUNT(column_name) FROM columns WHERE table_name = '#{table}' and column_name = '#{column}'") do |row|

        count = row[:count]
      end
      return count > 0
    end

    # get columns to be part of the SELECT query .. only when sql needs to be generated
    def get_columns(ds_structure)
      columns_sql = []
      columns_gd = []

      if ds_structure["extract_sql"]
        raise "something is wrong, generating colums for sql when custom sql given"
      end

      columns = ds_structure["columns"]

      # go through all the fields of the dataset
      columns.each do |csv_column_name, s|
        # push the gd short_identifier to list of csv columns
        columns_gd.push(csv_column_name)

        # if it's optional and it's not in the table, return empty
        if s["optional"]
          source_column = s["source_column"]
          if ! source_column
            raise "source column must be given for optional: #{f}"
          end

          if ! table_has_column(ds_structure["source_table"], source_column)
            columns_sql.push("'' AS #{csv_column_name}")
            next
          end
        end

        if !s
          raise "no source given for field: #{f}"
        end

        # if column name given, push it there directly
        if s["source_column"]
          columns_sql.push("#{s['source_column']} AS #{csv_column_name}")
          next
        end

        # same if source_column_expression given
        if s["source_column_expression"]
          columns_sql.push("#{s['source_column_expression']} AS #{csv_column_name}")
          next
        end

        # if there's something to be evaluated, do it
        if s["source_column_concat"]
          # through the stuff to be concated
          concat_strings = s["source_column_concat"].map do |c|
            # if it's a symbol get it from the load params
            if c[0] == ":"
              "'#{@params[:salesforce_downloaded_info][c[1..-1].to_sym]}'"
            else
              # take the value as it is, including apostrophes if any
              c
            end
          end
          columns_sql.push("(#{concat_strings.join(' || ')}) AS #{csv_column_name}")
          next
        end
        raise "column or source_column_concat must be given for #{f}"
      end
      return {
        :sql => columns_sql,
        :gd => columns_gd
      }
    end

    def get_load_info
      # get information from the meta table latest row
      # return it in form source_column name -> value
      select_sql = get_extract_load_info_sql
      info = {}
      execute_select(select_sql) do |row|
        info.merge!(row)
      end
      return info
    end

    # connect and pass execution to a block
    def connect
      Sequel.connect @params["dss_jdbc_url"],
        :username => @params["dss_GDC_USERNAME"],
        :password => @params["dss_GDC_PASSWORD"] do |connection|
          yield(connection)
      end
    end

    # executes sql (select), for each row, passes execution to block
    def execute_select(sql, fetch_handler=nil)
      connect do |connection|
        # do the query
        f = connection.fetch(sql)

        @logger.info("Executing sql: #{sql}") if @logger
        # if handler was passed call it
        if fetch_handler
          fetch_handler.call(f)
        end

        # go throug the rows returned and call the block
        return f.each do |row|
          yield(row)
        end
      end
    end

    # execute sql, return nothing
    def execute(sql_strings)
      if ! sql_strings.kind_of?(Array)
        sql_strings = [sql_strings]
      end
      connect do |connection|
          sql_strings.each do |sql|
            @logger.info("Executing sql: #{sql}") if @logger
            connection.run(sql)
          end
      end
    end

    private

    def sql_table_name(obj)
      pr = @params["dss_table_prefix"]
      user_prefix = pr ? "#{pr}_" : ""
      return "dss_#{user_prefix}#{obj}"
    end

    def obj_name(sql_table)
      return sql_table[4..-1]
    end

    ID_COLUMN = {"_oid" => "IDENTITY PRIMARY KEY"}

    HISTORIZATION_COLUMNS = [
      {"_LOAD_ID" => "VARCHAR(255)"},
      {"_INSERTED_AT" => "TIMESTAMP NOT NULL DEFAULT now()"},
      {"_IS_DELETED" => "boolean NOT NULL DEFAULT FALSE"},
    ]

    TYPE_MAPPING = {
      "date" => "DATE",
      "datetime" => "TIMESTAMP",
      "string" => "VARCHAR(255)",
      "double" => "DOUBLE PRECISION",
      "int" => "INTEGER",
      "currency" => "DECIMAL"
    }

    DEFAULT_TYPE = "VARCHAR (255)"

    def get_create_sql(table, fields)
      fields_string = fields.map{|f| "#{f[:name]} #{TYPE_MAPPING[f[:type]] || DEFAULT_TYPE}"}.join(", ")
      hist_columns = HISTORIZATION_COLUMNS.map {|col| "#{col.keys[0]} #{col.values[0]}"}.join(", ")
      return "CREATE TABLE IF NOT EXISTS #{sql_table_name(table)}
      (#{ID_COLUMN.keys[0]} #{ID_COLUMN.values[0]}, #{fields_string}, #{hist_columns})"
    end

    def get_except_filename(filename)
      return "#{filename}.except.log"
    end

    def get_reject_filename(filename)
      return "#{filename}.reject.log"
    end

    # filename is absolute
    def get_upload_sql(table, fields, filename, load_id)
      return %Q{COPY #{sql_table_name(table)} (#{fields.map {|f| f[:name]}.join(', ')}, _LOAD_ID AS '#{load_id}')
      FROM LOCAL '#{filename}' WITH PARSER GdcCsvParser()
      ESCAPE AS '"'
       SKIP 1
      EXCEPTIONS '#{get_except_filename(filename)}'
      REJECTED DATA '#{get_reject_filename(filename)}' }
    end

    def get_extract_sql(table, columns)
      # TODO last snapshot
      return "SELECT #{columns.join(',')} FROM #{table} WHERE _INSERTED_AT = (SELECT MAX(_LOAD_ID) FROM #{LOAD_INFO_TABLE_NAME})"
    end

    def get_extract_load_info_sql
      table_name = sql_table_name(LOAD_INFO_TABLE_NAME)
      return "SELECT * FROM #{table_name} WHERE _INSERTED_AT = (SELECT MAX(_INSERTED_AT) FROM #{table_name})"
    end

    def get_insert_sql(table, column_values)
      columns = column_values.keys
      values = column_values.values_at(*columns)
      values_string = values.map {|e| "'#{e}'"}.join(',')

      return "INSERT INTO #{table} (#{columns.join(',')}) VALUES (#{values_string})"
    end
  end
end