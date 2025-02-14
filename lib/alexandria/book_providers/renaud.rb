# frozen_string_literal: true

# This file is part of Alexandria.
#
# See the file README.md for authorship and licensing information.

# http://en.wikipedia.org/wiki/Renaud-Bray

require 'net/http'
require 'cgi'

module Alexandria
  class BookProviders
    class RENAUDProvider < GenericProvider
      include GetText
      # GetText.bindtextdomain(Alexandria::TEXTDOMAIN, :charset => "UTF-8")
      BASE_URI = 'http://www.renaud-bray.com/'
      ACCENTUATED_CHARS = 'áàâäçéèêëíìîïóòôöúùûü'

      def initialize
        super('RENAUD', 'Renaud-Bray (Canada)')
      end

      def search(criterion, type)
        criterion = criterion.encode('ISO-8859-1')
        req = BASE_URI +
          'francais/menu/gabarit.asp?Rubrique=&Recherche=&Entete=Livre' \
          '&Page=Recherche_wsc.asp&OnlyAvailable=false&Tri='
        req += case type
               when SEARCH_BY_ISBN
                 'ISBN'
               when SEARCH_BY_TITLE
                 'Titre'
               when SEARCH_BY_AUTHORS
                 'Auteur'
               when SEARCH_BY_KEYWORD
                 ''
               else
                 raise InvalidSearchTypeError
               end
        req += '&Phrase='

        req += CGI.escape(criterion)
        p req if $DEBUG
        data = transport.get(URI.parse(req))
        begin
          if type == SEARCH_BY_ISBN
            return to_books(data).pop
          else
            results = []
            to_books(data).each { |book|
              results << book
            }
            while /Suivant/ =~ data
              md = /Enteterouge\">([\d]*)<\/b>/.match(data)
              num = md[1].to_i + 1
              data = transport.get(URI.parse(req + '&PageActuelle=' + num.to_s))
              to_books(data).each { |book|
                results << book
              }
            end
            return results
          end
        rescue StandardError
          raise NoResultsError
        end
      end

      def url(book)
        'http://www.renaud-bray.com/francais/menu/gabarit.asp?Rubrique=&Recherche=' \
          '&Entete=Livre&Page=Recherche_wsc.asp&OnlyAvailable=false&Tri=ISBN&Phrase=' + book.isbn
      end

      private

      NO_BOOKS_FOUND_REGEXP =
        /<strong class="Promotion">Aucun article trouv. selon les crit.res demand.s<\/strong>/.freeze
      HYPERLINK_SCAN_REGEXP =
        /"(Jeune|Lire)Hyperlien" href.*><strong>([-,'\(\)&\#;\w\s#{ACCENTUATED_CHARS}]*)<\/strong><\/a><br>/.
          freeze

      def to_books(data)
        data = CGI.unescapeHTML(data)
        data = data.encode('UTF-8')
        raise NoResultsError if NO_BOOKS_FOUND_REGEXP.match?(data)

        titles = []
        data.scan(HYPERLINK_SCAN_REGEXP).each { |md|
          titles << md[1].strip
        }
        raise if titles.empty?

        authors = []
        data.scan(/Nom_Auteur.*><i>([,'.&\#;\w\s#{ACCENTUATED_CHARS}]*)<\/i>/).each { |md|
          authors2 = []
          md[0].split('  ').each do |author|
            authors2 << author.strip
          end
          authors << authors2
        }
        raise if authors.empty?

        isbns = []
        data.scan(/ISBN : ?<\/td><td>(\d+)/).each { |md|
          isbns << md[0].strip
        }
        raise if isbns.empty?

        editions = []
        publish_years = []
        data.scan(/Parution : <br>(\d{4,}-\d{2,}-\d{2,})/).each { |md|
          editions << md[0].strip
          publish_years << md[0].strip.split(/-/)[0].to_i
        }
        raise if editions.empty? || publish_years.empty?

        publishers = []
        data.scan(/diteur : ([,'.&\#;\w\s#{ACCENTUATED_CHARS}]*)<\/span><br>/).each { |md|
          publishers << md[0].strip
        }
        raise if publishers.empty?

        book_covers = []
        data.scan(/(\/ImagesEditeurs\/[\d]*\/([\dX]*-f.(jpg|gif))
                    |\/francais\/suggestion\/images\/livre\/livre.gif)/x).each { |md|
          book_covers << BASE_URI + md[0].strip
        }
        raise if book_covers.empty?

        books = []
        titles.each_with_index { |title, i|
          books << [Book.new(title, authors[i], isbns[i], publishers[i], publish_years[i], editions[i]),
                    book_covers[i]]
          # print books
        }
        raise if books.empty?

        books
      end
    end
  end
end
