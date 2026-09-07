class SpcFile
    class Error < StandardError; end
  
    # パース結果を格納するデータ構造
    SpcParsed = Struct.new(
      :pc, :a, :x, :y, :psw, :sp,
      :song_title, :game_title, :dumper_name, :comments, :artist,
      :ram, :dsp_regs,
      keyword_init: true
    )
  
    MIN_SIZE = 0x10100 + 0x80 # 65,920 バイト
  
    def self.parse(binary_data)
      buf = binary_data.b # バイナリ(ASCII-8BIT)として扱う
  
      # サイズ検証
      if buf.bytesize < MIN_SIZE
        raise Error, "SPCファイルが小さすぎます（サイズ不正）"
      end
  
      # シグネチャ検証
      unless buf.start_with?("SNES-SPC700".b)
        raise Error, "SPCファイルのヘッダが不正です（SNES-SPC700シグネチャが見つかりません）"
      end
  
      # レジスタ抽出 (0x25 から 16bit LE + 8bit x 5)
      pc, a, x, y, psw, sp = buf.byteslice(0x25, 7).unpack("vC5")
  
      # タグ文字列抽出
      song_title  = read_tag_string(buf, 0x2e, 32)
      game_title  = read_tag_string(buf, 0x4e, 32)
      dumper_name = read_tag_string(buf, 0x6e, 16)
      comments    = read_tag_string(buf, 0x7e, 32)
      artist      = read_tag_string(buf, 0xb1, 32)
  
      # メモリ領域切り出し
      ram      = buf.byteslice(0x100, 0x10000)
      dsp_regs = buf.byteslice(0x10100, 0x80)
  
      SpcParsed.new(
        pc: pc, a: a, x: x, y: y, psw: psw, sp: sp,
        song_title: song_title,
        game_title: game_title,
        dumper_name: dumper_name,
        comments: comments,
        artist: artist,
        ram: ram,
        dsp_regs: dsp_regs
      )
    end
  
    private
  
    # Shift-JIS -> UTF-8 変換（失敗時は Raw Bytes / ISO-8859-1 扱い）および末尾空白トリム
    def self.read_tag_string(buf, offset, length)
      slice = buf.byteslice(offset, length) || "".b
      
      # NUL終端 (\0) で切断
      null_idx = slice.index("\x00".b)
      slice = slice[0...null_idx] if null_idx
  
      return "" if slice.empty?
  
      decoded = begin
        # Shift_JIS から UTF-8 へ変換
        slice.encode('UTF-8', 'Shift_JIS')
      rescue Encoding::Error
        # 失敗時は ISO-8859-1 (Latin1) としてUTF-8にフォールバック
        slice.force_encoding('ISO-8859-1').encode('UTF-8')
      end
  
      # 末尾の空白類 (スペース, \t, \r, \n) を削除
      decoded.sub(/[ \t\r\n]+\z/, '')
    end
  end