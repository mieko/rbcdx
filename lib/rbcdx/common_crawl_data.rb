require "fileutils"
require "json"
require "net/http"
require "stringio"
require "tempfile"
require "uri"
require "zlib"

module CDX
  class CommonCrawlData
    CRAWL_LIST_URL = "https://index.commoncrawl.org/collinfo.json"
    DATA_BASE_URL = "https://data.commoncrawl.org"

    Crawl = Struct.new(:id, :name, :from, :to) do
      def to_h
        {
          "id" => id,
          "name" => name,
          "from" => from,
          "to" => to
        }
      end
    end

    IndexFile = Struct.new(:crawl_id, :path, :url) do
      def filename
        File.basename(path)
      end

      def destination(output_dir)
        File.join(output_dir, crawl_id, filename)
      end

      def to_h
        {
          "crawl" => crawl_id,
          "path" => path,
          "url" => url
        }
      end
    end

    DownloadResult = Struct.new(:file, :destination, :status)

    def initialize(fetcher: nil, downloader: nil)
      @fetcher = fetcher || method(:fetch_url)
      @downloader = downloader || method(:download_url)
    end

    def crawls
      JSON.parse(fetch(CRAWL_LIST_URL)).map do |entry|
        Crawl.new(entry.fetch("id"), entry["name"], entry["from"], entry["to"])
      end
    rescue JSON::ParserError => error
      raise Error, "failed to parse Common Crawl crawl list: #{error.message}"
    end

    def latest_crawl
      crawls.first || raise(Error, "Common Crawl crawl list is empty")
    end

    def index_files(crawl_id, limit: nil, zipnum: true)
      parse_index_paths(crawl_id, fetch(index_paths_url(crawl_id)), limit: limit, zipnum: zipnum).map do |path|
        IndexFile.new(crawl_id, path, index_file_url(path))
      end
    end

    def download_indexes(crawl_id:, output_dir:, limit: nil, force: false, zipnum: true, progress: nil)
      files = index_files(crawl_id, limit: limit, zipnum: zipnum)
      files.map.with_index(1) do |file, index|
        destination = file.destination(output_dir)
        if File.exist?(destination) && !force
          emit_progress(progress, :skip, file: file, destination: destination, index: index, total: files.length)
          DownloadResult.new(file, destination, :skipped)
        else
          emit_progress(progress, :start, file: file, destination: destination, index: index, total: files.length)
          download_to_destination(file.url, destination) do |downloaded_bytes:, total_bytes:|
            emit_progress(
              progress,
              :progress,
              file: file,
              destination: destination,
              index: index,
              total: files.length,
              downloaded_bytes: downloaded_bytes,
              total_bytes: total_bytes
            )
          end
          emit_progress(progress, :finish, file: file, destination: destination, index: index, total: files.length)
          DownloadResult.new(file, destination, :downloaded)
        end
      end
    end

    def parse_index_paths(crawl_id, gzipped_paths, limit: nil, zipnum: true)
      paths = Zlib::GzipReader.wrap(StringIO.new(gzipped_paths)) { |gzip| gzip.each_line.map(&:strip) }
      cdx_paths = paths.select { |path| cdx_path?(crawl_id, path) }
      cdx_paths = cdx_paths.first(limit) if limit

      return cdx_paths if cdx_paths.empty? || !zipnum

      cdx_paths + paths.select { |path| zipnum_path?(crawl_id, path) }
    rescue Zlib::GzipFile::Error => error
      raise Error, "failed to read Common Crawl index file list: #{error.message}"
    end

    def index_paths_url(crawl_id)
      "#{DATA_BASE_URL}/crawl-data/#{crawl_id}/cc-index.paths.gz"
    end

    def index_file_url(path)
      "#{DATA_BASE_URL}/#{path}"
    end

    private

    def fetch(url)
      @fetcher.call(url)
    rescue Error
      raise
    rescue => error
      raise Error, "failed to fetch #{url}: #{error.message}"
    end

    def fetch_url(url)
      body = +""
      http_get(url, "fetch") do |response|
        response.read_body { |chunk| body << chunk }
      end
      body
    end

    def download_url(url, destination, progress: nil)
      http_get(url, "download") do |response|
        total_bytes = response["content-length"]&.to_i
        downloaded_bytes = 0
        progress&.call(downloaded_bytes: downloaded_bytes, total_bytes: total_bytes)
        File.open(destination, "wb") do |output|
          response.read_body do |chunk|
            output.write(chunk)
            downloaded_bytes += chunk.bytesize
            progress&.call(downloaded_bytes: downloaded_bytes, total_bytes: total_bytes)
          end
        end
      end
    end

    def download_to_destination(url, destination, &progress)
      FileUtils.mkdir_p(File.dirname(destination))

      tempfile = Tempfile.new(["#{File.basename(destination)}.", ".tmp"], File.dirname(destination))
      temp_path = tempfile.path
      tempfile.close

      call_downloader(url, temp_path, progress)
      File.rename(temp_path, destination)
    rescue Error
      raise
    rescue => error
      raise Error, "failed to download #{url}: #{error.message}"
    ensure
      tempfile&.close!
    end

    def call_downloader(url, destination, progress)
      parameters = downloader_parameters
      if parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == :progress } ||
          parameters.any? { |kind, _name| kind == :keyrest }
        @downloader.call(url, destination, progress: progress)
      else
        @downloader.call(url, destination)
      end
    end

    def downloader_parameters
      return @downloader.parameters if @downloader.respond_to?(:parameters)
      return @downloader.method(:call).parameters if @downloader.respond_to?(:call)

      []
    end

    def emit_progress(progress, event, **payload)
      progress&.call(event, **payload)
    end

    def http_get(url, action)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise Error, "failed to #{action} #{url}: HTTP #{response.code}"
          end

          yield response
        end
      end
    rescue Error
      raise
    rescue => error
      raise Error, "failed to #{action} #{url}: #{error.message}"
    end

    def cdx_path?(crawl_id, path)
      path.match?(%r{\Acc-index/collections/#{Regexp.escape(crawl_id)}/indexes/cdx-\d+\.gz\z})
    end

    def zipnum_path?(crawl_id, path)
      path == "cc-index/collections/#{crawl_id}/indexes/cluster.idx"
    end
  end
end
