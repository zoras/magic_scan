require 'magic_scan'
require 'tempfile'
require 'webrick'
require 'json'

image_queue = Queue.new

Thread.abort_on_exception = true

server = WEBrick::HTTPServer.new :Port => 8000, :DocumentRoot => ARGV[0]

def image_to_json img
  {
    'picture' => [File.read(img.filename)].pack('m'),
    'distance' => img.distance,
    'cards' => img.cards.map { |card|
      { 'name' => card.name, 'id' => card.id }
    }
  }
end

Thread.new {
  server.mount_proc '/cards' do |req, res|
    query    = req.query
    img      = query['scanned_card'].unpack('m').first
    card_ids = query['card_ids'].split(',').map(&:to_i)
    cards    = Card.where(:id => card_ids).to_a
    user_img = UserImage.build_from_bytes img

    UserImage.transaction do
      user_img.save!
      cards.each do |card|
        card.images << user_img
      end
    end
    res.body = "saved: #{cards.map(&:name).join(", ")}"
  end

  server.mount_proc '/stream' do |req, res|
    rd, wr = IO.pipe
    res['Content-Type'] = 'text/event-stream'
    res.body = rd
    res.chunked = true
    Thread.new {
      while job = image_queue.pop
        image, ref_images = job
        data = {
          "scanned_image" => [image].pack('m'),
          "matches"       => ref_images
        }
        begin
          wr.write "data: #{JSON.dump(data)}\n\n"
        rescue Errno::EPIPE
          wr.close
          break
        end
      end
    }
  end

  server.start
}

def detect_cards img
  tf = Tempfile.open 'card.jpg'
  tf.binmode
  tf.write img
  tf.flush
  hash = Phashion.image_hash_for tf.path
  refs = Image.find_similar(hash, 3).to_a
  tf.close
  tf.unlink
  refs
end

MagicScan::Photo.run do |conn|
  loop do
    img = loop {
      full_image = OpenCV::IplImage.decode_image conn.take_photo.bytes
      data = MagicScan::Photo.find_and_crop full_image, 233, 310
      break(data) if data
    }

    puts "got img"
    refs = detect_cards img

    if refs.any?
      image_queue << [img, refs.map { |r| image_to_json r }]
      sleep 1
    else
      print "."
    end
  end
end

trap('INT') { server.shutdown }
