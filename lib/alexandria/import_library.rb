# frozen_string_literal: true

# This file is part of Alexandria.
#
# See the file README.md for authorship and licensing information.

require 'gettext'
require 'tmpdir'

module Alexandria
  class ImportFilter
    attr_reader :name, :patterns, :message

    include GetText
    extend GetText
    bindtextdomain(Alexandria::TEXTDOMAIN, charset: 'UTF-8')

    def self.all
      [
        new(_('Autodetect'), ['*'], :import_autodetect),
        new(_('Archived Tellico XML (*.bc, *.tc)'),
            ['*.tc', '*.bc'], :import_as_tellico_xml_archive),
        new(_('ISBN List (*.txt)'), ['*.txt'], :import_as_isbn_list),
        new(_('GoodReads CSV'), ['*.csv'], :import_as_csv_file)
      ]
    end

    def on_iterate(&on_iterate_cb)
      @on_iterate_cb = on_iterate_cb
    end

    def on_error(&on_error_cb)
      @on_error_cb = on_error_cb
    end

    def invoke(library_name, filename)
      puts "Selected: #{@message} -- #{library_name} -- #{filename}"
      Library.send(@message, library_name, filename,
                   @on_iterate_cb, @on_error_cb)
    end

    private

    def initialize(name, patterns, message)
      @name = name
      @patterns = patterns
      @message = message
    end
  end

  class Library
    def self.import_autodetect(*args)
      puts args.inspect
      filename = args[1]
      puts "Filename is #{filename} and ext is #{filename[-4..-1]}"
      puts "Beginning import: #{args[0]}, #{args[1]}"
      if filename[-4..-1] == '.txt'
        import_as_isbn_list(*args)
      elsif ['.tc', '.bc'].include? filename[-3..-1]
        begin
          import_as_tellico_xml_archive(*args)
        rescue StandardError => ex
          puts ex.message
          puts ex.backtrace.join("\n>> ")
        end
      elsif ['.csv'].include? filename[-4..-1]
        import_as_csv_file(*args)
      else
        puts 'Bailing on this import!'
        raise 'Not supported type'
      end
    end

    def self.import_as_tellico_xml_archive(name, filename,
                                           on_iterate_cb, _on_error_cb)
      puts 'Starting import_as_tellico_xml_archive... '
      return nil unless system("unzip -qqt \"#{filename}\"")

      tmpdir = File.join(Dir.tmpdir, 'tellico_export')
      FileUtils.rm_rf(tmpdir) if File.exist?(tmpdir)
      Dir.mkdir(tmpdir)
      Dir.chdir(tmpdir) do
        begin
          system("unzip -qq \"#{filename}\"")
          file = File.exist?('bookcase.xml') ? 'bookcase.xml' : 'tellico.xml'
          xml = REXML::Document.new(File.open(file))
          raise unless ['bookcase', 'tellico'].include? xml.root.name
          # FIXME: handle multiple collections
          raise unless xml.root.elements.size == 1

          collection = xml.root.elements[1]
          raise unless collection.name == 'collection'

          type = collection.attribute('type').value.to_i
          raise unless (type == 2) || (type == 5)

          content = []
          entries = collection.elements.to_a('entry')
          (total = entries.size).times do |n|
            entry = entries[n]
            elements = entry.elements
            # Feed an array in here, tomorrow.
            keys = ['isbn', 'publisher', 'pub_year', 'binding']

            book_elements = [neaten(elements['title'].text)]
            book_elements += if !elements['authors'].nil?
                               [elements['authors'].elements.to_a.map \
                                                 { |x| neaten(x.text) }]
                             else
                               [[]]
                             end
            book_elements += keys.map { |key|
              neaten(elements[key].text) if elements[key]
            }
            # isbn
            if book_elements[2].nil? || book_elements[2].strip.empty?
              book_elements[2] = nil
            else
              begin
                book_elements[2] = book_elements[2].strip
                book_elements[2] = Library.canonicalise_ean(book_elements[2])
              rescue StandardError => ex
                puts book_elements[2]
                puts ex.message
                puts ex.backtrace.join("\n> ")
                raise ex
              end
            end
            book_elements[4] = book_elements[4].to_i unless book_elements[4].nil? # publishing_year
            puts book_elements.inspect
            cover = (neaten(elements['cover'].text) if elements['cover'])
            puts cover
            book = Book.new(*book_elements)
            if elements['rating'] && Book::VALID_RATINGS.member?(elements['rating'].text.to_i)
              book.rating = elements['rating'].text.to_i
            end
            book.notes = neaten(elements['comments'].text) if elements['comments']
            content << [book, cover]
            on_iterate_cb&.call(n + 1, total)
          end

          library = Library.load(name)
          content.each do |book, cover|
            unless cover.nil?
              library.save_cover(book,
                                 File.join(Dir.pwd, 'images',
                                           cover))
            end
            library << book
            library.save(book)
          end
          return [library, []]
        rescue StandardError => ex
          puts ex.message
          return nil
        end
      end
    end

    def self.import_as_csv_file(name, filename, on_iterate_cb, _on_error_cb)
      require 'alexandria/import_library_csv'
      books_and_covers = []
      line_count = IO.readlines(filename).reduce(0) { |count, _line| count + 1 }

      import_count = 0
      max_import = line_count - 1

      reader = CSV.open(filename, 'r')
      # Goodreads & LibraryThing now use csv header lines
      header = reader.shift
      importer = identify_csv_type(header)
      failed_once = false
      begin
        reader.each do |row|
          book = importer.row_to_book(row)
          cover = nil
          if book.isbn
            # if we can search by ISBN, try to grab the cover
            begin
              dl_book, dl_cover = Alexandria::BookProviders.isbn_search(book.isbn)
              if dl_book.authors.size > book.authors.size
                # LibraryThing only supports a single author, so
                # attempt to include more author information if it's
                # available
                book.authors = dl_book.authors
              end
              book.edition = dl_book.edition unless book.edition
              cover = dl_cover
            rescue StandardError
              puts "failed to get cover for #{book.title} #{book.isbn}" if $DEBUG
              # note failure
            end
          end

          books_and_covers << [book, cover]
          import_count += 1
          on_iterate_cb&.call(import_count, max_import)
        end
      rescue CSV::IllegalFormatError
        unless failed_once
          failed_once = true

          # probably Goodreads' wonky ISBN fields ,,="043432432X",
          # this is a hack to fix up such files
          data = File.read(filename)
          data.gsub!(/\,\=\"/, ',"')
          csv_fixed = Tempfile.new('alexandria_import_csv_fixed_')
          csv_fixed.write(data)
          csv_fixed.close

          reader = CSV.open(csv_fixed.path, 'r')
          header = reader.shift
          importer = identify_csv_type(header)

          retry
        end
      end

      library = Library.load(name)

      books_and_covers.each do |book, cover_uri|
        puts "Saving #{book.isbn} cover..." if $DEBUG
        library.save_cover(book, cover_uri) unless cover_uri.nil?
        puts "Saving #{book.isbn}..." if $DEBUG
        library << book
        library.save(book)
      end
      [library, []]
    end

    def self.import_as_isbn_list(name, filename, on_iterate_cb,
                                 on_error_cb)
      puts 'Starting import_as_isbn_list... '
      isbn_list = IO.readlines(filename).map do |line|
        puts "Trying line #{line}" if $DEBUG
        # Let's preserve the failing isbns so we can report them later.
        begin
          [line.chomp, canonicalise_isbn(line.chomp)] unless line == "\n"
        rescue StandardError => ex
          puts ex.message
          [line.chomp, nil]
        end
      end
      puts "Isbn list: #{isbn_list.inspect}"
      isbn_list.compact!
      return nil if isbn_list.empty?

      max_iterations = isbn_list.length * 2
      current_iteration = 1
      books = []
      bad_isbns = []
      failed_lookup_isbns = []
      isbn_list.each do |isbn|
        begin
          if isbn[1]
            books << Alexandria::BookProviders.isbn_search(isbn[1])
          else
            bad_isbns << isbn[0]
          end
        rescue StandardError => ex
          puts ex.message
          failed_lookup_isbns << isbn[1]
          puts "NOTE : ignoring on_error_cb #{on_error_cb}"
          # return nil unless
          #  (on_error_cb and on_error_cb.call(e.message))
        end

        on_iterate_cb&.call(current_iteration += 1, max_iterations)
      end
      puts "Bad Isbn list: #{bad_isbns.inspect}" if bad_isbns
      library = load(name)
      puts "Going with these #{books.length} books: #{books.inspect}" if $DEBUG
      books.each do |book, cover_uri|
        puts "Saving #{book.isbn} cover..." if $DEBUG
        library.save_cover(book, cover_uri) unless cover_uri.nil?
        puts "Saving #{book.isbn}..." if $DEBUG
        library << book
        library.save(book)
        on_iterate_cb&.call(current_iteration += 1, max_iterations)
      end
      [library, bad_isbns, failed_lookup_isbns]
    end

    def self.neaten(str)
      if str
        str.strip
      else
        str
      end
    end
  end
end
