# frozen_string_literal: true

# This file is part of Alexandria.
#
# See the file README.md for authorship and licensing information.

# AdLibris  Bokhandel AB http://www.adlibris.com/se/
# Swedish online book store

# New AdLibris provider, taken from the Palatina MetaDataSource and
# modified to fit the structure of Alexandria book providers.
# (26 Feb 2009)

require 'cgi'
require 'alexandria/book_providers/web'

module Alexandria
  class BookProviders
    class AdLibrisProvider < WebsiteBasedProvider
      include Alexandria::Logging

      SITE = 'http://www.adlibris.com/se/'

      BASE_SEARCH_URL = "#{SITE}searchresult.aspx?search=advanced&%s=%s" \
        '&fromproduct=False' # type/term

      PRODUCT_URL = "#{SITE}product.aspx?isbn=%s"

      def initialize
        super('AdLibris', 'AdLibris (Sweden)')
        prefs.read
        # @ent = HTMLEntities.new
      end

      ## search (copied from new WorldCat search)
      def search(criterion, type)
        req = create_search_uri(type, criterion)
        log.info { "Fetching #{req} " }
        html_data = transport.get_response(URI.parse(req))

        if type == SEARCH_BY_ISBN
          parse_result_data(html_data.body)
        else
          results = parse_search_result_data(html_data.body)
          raise NoResultsError if results.empty?

          results.map { |result| get_book_from_search_result(result) }
        end
      end

      ## url
      def url(book)
        create_search_uri(SEARCH_BY_ISBN, book.isbn)
      rescue StandardError => ex
        log.warn { "Cannot create url for book #{book}; #{ex.message}" }
        nil
      end

      private

      def create_search_uri(search_type, search_term)
        if search_type == SEARCH_BY_ISBN
          PRODUCT_URL % Library.canonicalise_isbn(search_term)
        else
          (search_type_code = {
            SEARCH_BY_AUTHORS => 'author',
            SEARCH_BY_TITLE   => 'title',
            SEARCH_BY_KEYWORD => 'keyword'
          }[search_type]) || 'keyword'
          search_term_encoded = CGI.escape(search_term)
          format(BASE_SEARCH_URL, search_type_code, search_term_encoded)
        end
      end

      # TODO: use Iconv to pre-convert the html.body to UTF-8 everywhere
      # before sending it to the parser methods

      def get_book_from_search_result(rslt)
        html_data = transport.get_response(URI.parse(rslt[:lookup_url]))
        parse_result_data(html_data.body)
      end

      def parse_search_result_data(html)
        # adlibris site presents data in ISO-8859-1, so change it to UTF-8
        # html = Iconv.conv("UTF-8", "ISO-8859-1", html)
        # doc = Hpricot(html)
        doc = html_to_doc(html)
        book_search_results = []

        search_hit = doc.search("div'searchResult")[0]
        return [] unless search_hit

        (search_hit / 'ul.ulSearch table').each do |t|
          result = {}
          if (title_data = (t % 'div.divTitle'))
            result[:title] = (title_data % :a).inner_text
            lookup_url = (title_data % :a)['href']
          end
          result[:lookup_url] = "#{SITE}#{lookup_url}"

          book_search_results << result
        end
        book_search_results
      end

      # def binding_type(binding) # swedish string
      #  # hrm, this is a HACK and not currently working
      #  # perhaps use regexes instead...
      #  {"inbunden" => :hardback,
      #    "pocket" => :paperback,
      #    "storpocket" => :paperback,
      #    "kartonnage" => :hardback,
      #    "kassettbok" => :audiobook}[binding.downcase] or :paperback
      #  # H&#228;ftad == Paperback
      # end

      def normalize(text)
        # unless text.nil?
        #  text = @ent.decode(text).strip
        # end
        text
      end

      def parse_result_data(html)
        # adlibris site presents data in ISO-8859-1, so change it to UTF-8
        # html = Iconv.conv("UTF-8", "ISO-8859-1", html)
        ## File.open(',log.html', 'wb') {|f| f.write('<?xml encoding="utf-8"?>'); f.write(html) } # DEBUG
        # doc = Hpricot(html)
        doc = html_to_doc(html)
        begin
          title = nil
          if (h1 = doc.at('div.productTitleFormat h1'))
            title = text_of(h1)
          else
            raise NoResultsError, 'title not found on page'
          end

          product = doc.at('div.product')
          ul_info = doc.at('ul.info') # NOTE, two of these

          author_cells = ul_info.search('li.liAuthor') # css-like search
          authors = []
          author_cells.each do |li|
            author_name = text_of(li.search('h2 > a')[0])

            authors << author_name
          end

          publisher = nil
          if (publisher_elem = product.search('li[@id$="liPublisher"] a').first)
            publisher = text_of(publisher_elem)
          end

          binding = nil
          if (format = doc.search('div.productTitleFormat span').first)
            binding = text_of(format)
            binding = Regexp.last_match[1] if binding =~ /\(([^\)]+)\)/
          end

          year = nil
          if (published = product.search('span[@id$="Published"]').first)
            publication = published.inner_text
            year = Regexp.last_match[1].to_i if publication =~ /([12][0-9]{3})/
          end

          isbns = []
          isbn_tds = doc.search("li[@id *= 'liISBN'] td[text()]")

          isbn_tds.each do |isbn_td|
            isbn = isbn_td.inner_text
            next unless isbn =~ /[0-9x]{10,13}/i

            isbn.gsub(/(\n|\r)/, ' ')
            isbn = Regexp.last_match[1] if isbn =~ /:[\s]*([0-9x]+)/i
            isbns << isbn
          end
          isbn = isbns.first
          isbn = Library.canonicalise_isbn(isbn) if isbn

          # cover
          image_url = nil
          if (cover_img = doc.search('span.imageWithShadow img[@id$="ProductImageNotLinked"]').first)
            image_url = if /^http\:\/\//.match?(cover_img['src'])
                          cover_img['src']
                        else
                          "#{SITE}/#{cover_img['src']}" # HACK: use html base
                        end
            if /noimage.gif$/.match?(image_url)
              # no point downloading a "no image" graphic
              # Alexandria has its own generic book icon...
              image_url = nil
            end

          end

          book = Book.new(title, authors, isbn, publisher, year, binding)

          return [book, image_url]
        rescue StandardError => ex
          raise ex if ex.instance_of? NoResultsError

          trace = ex.backtrace.join("\n> ")
          log.warn {
            'Failed parsing search results for AdLibris ' \
            "#{ex.message} #{trace}"
          }
          raise NoResultsError
        end
      end
    end
  end
end
