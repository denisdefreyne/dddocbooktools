# encoding: utf-8

require 'prawn'

class DDDocBookTools::Renderers::PDF

  def initialize(doc, output_filename, config)
    @doc = doc
    @output_filename = output_filename
    @config = config
  end

  def run
    Prawn::Document.generate(@output_filename) do |pdf|
      setup_fonts(pdf)
      setup_defaults(pdf)

      state = DDDocBookTools::State.new
      RootRenderer.new(@doc, pdf, state).process
    end
  end

  private

  def setup_fonts(pdf)
    @config[:fonts].each_pair do |name, variants|
      pdf.font_families.update(name => variants)
    end
  end

  def setup_defaults(pdf)
    pdf.font            @config[:defaults][:font]
    pdf.font_size       @config[:defaults][:font_size]
    pdf.default_leading @config[:defaults][:leading]
  end

  class NodeRenderer

    def initialize(node, pdf, state)
      @node  = node
      @pdf   = pdf
      @state = state
    end

    def process
      raise 'abstract'
    end

    def notify_unhandled(node)
      puts "*** #{self.class.to_s}: unhandled element: #{node.name}"
    end

    def handle_children(map)
      @node.children.map do |node|
        klass = map[node.name]
        if klass
          klass.new(node, @pdf, @state).process
        else
          notify_unhandled(node)
          nil
        end
      end
    end

  end

  class RootRenderer < NodeRenderer

    def process
      handle_children({ 'book' => BookRenderer })
    end

  end

  class BookRenderer < NodeRenderer

    def process
      @pdf.repeat(:all, dynamic: true) do
        @pdf.stroke_horizontal_line(50, @pdf.bounds.width - 50, at: 20)
        at = [ 50, 14 ]
        @pdf.font('PT Sans', size: 10) do
          current_chapter = @state.chapters.reverse_each.with_index.find { |e,i| e ? e[0] <= @pdf.page_number : false }
          current_section = @state.sections.reverse_each.with_index.find { |e,i| e ? e[0] <= @pdf.page_number : false }

          next if current_chapter.nil? || current_section.nil?

          text = ''
          if @pdf.page_number.even?
            text << @pdf.page_number.to_s
            text << '   |   '
            text << "Chapter #{current_chapter[0][2]}: #{current_chapter[0][1]}"
            align = :left
          else
            text << "#{current_section[0][1]}"
            text << '   |   '
            text << @pdf.page_number.to_s
            align = :right
          end
          @pdf.text_box(text, at: at, size: 9, width: @pdf.bounds.width - 100, align: align)
        end
      end

      @pdf.bounding_box([ 50, @pdf.bounds.height - 30 ], width: @pdf.bounds.width - 100, height: @pdf.bounds.height - 70) do
        handle_children({
          'chapter' => ChapterRenderer,
          'section' => SectionRenderer,
        })
      end
    end

  end

  class ChapterRenderer < NodeRenderer

    def process
      @pdf.start_new_page
      handle_children({
        'title'   => ChapterTitleRenderer,
        'section' => SectionRenderer,
        'para'    => ParaRenderer,
      })
    end

  end

  class ChapterTitleRenderer < NodeRenderer

    def process
      text = @node.children.find { |e| e.text? }

      @pdf.bounding_box([0, @pdf.bounds.height - 50], width: @pdf.bounds.width) do
        @pdf.font('PT Sans', size: 32, style: :bold) do
          @pdf.text text.text, align: :right
        end
      end
      @pdf.move_down(100)
      @state.add_chapter(text.text, @pdf.page_number)
    end

  end

  class SectionRenderer < NodeRenderer

    def process
      @pdf.indent(indent, indent) do
        handle_children({
          'simpara'        => SimparaRenderer,
          'para'           => ParaRenderer,
          'programlisting' => ProgramListingRenderer,
          'screen'         => ScreenRenderer,
          'title'          => section_title_renderer_class,
          'note'           => NoteRenderer,
          'section'        => SubsectionRenderer,
          'figure'         => FigureRenderer,
        })
      end

      @pdf.move_down(20)
    end

    def indent
      0
    end

    def section_title_renderer_class
      SectionTitleRenderer
    end

  end

  class SectionTitleRenderer < NodeRenderer

    def process
      text = @node.children.find { |e| e.text? }

      @pdf.indent(indent, indent) do
        @pdf.formatted_text [ { text: text.text, font: 'PT Sans', styles: [ :bold ], size: font_size } ]
      end
      @pdf.move_down(10)
      @state.add_section(text.text, @pdf.page_number)
    end

    def level
      3
    end

    def indent
      0
    end

    def font_size
      20
    end

  end

  class SubsectionRenderer < SectionRenderer

    def section_title_renderer_class
      SubsectionTitleRenderer
    end

    def indent
      0
    end

  end

  class SubsectionTitleRenderer < SectionTitleRenderer

    def level
      4
    end

    def indent
      0
    end

    def font_size
      14
    end

  end

  class NoteRenderer < NodeRenderer

    def process
      @pdf.indent(20) do
        @pdf.formatted_text [ { text: 'NOTE', styles: [ :bold ], font: 'PT Sans' } ]
        handle_children({
          'simpara' => SimparaRenderer,
          'para'    => ParaRenderer,
        })
      end
    end

  end

  class FigureRenderer < NodeRenderer

    def process
      # Title
      title = @node.children.find { |e| e.name == 'title' }
      text = title.children.find { |e| e.text? }.text

      # Image
      mediaobject = @node.children.find       { |e| e.name == 'mediaobject' }
      imageobject = mediaobject.children.find { |e| e.name == 'imageobject' }
      imagedata   = imageobject.children.find { |e| e.name == 'imagedata' }
      href = imagedata[:fileref]

      @pdf.indent(30, 30) do
        @pdf.image(href, width: @pdf.bounds.width)
        @pdf.formatted_text([
          { text: 'Figure: ', styles: [ :bold ],   font: 'PT Sans' },
          { text: text,       styles: [ :italic ], font: 'Gentium Basic' }
          ])
        @pdf.move_down 10
      end
    end

  end

  class TextRenderer < NodeRenderer

    def process
      { text: @node.text.gsub(/\s+/, ' ') }
    end

  end

  class PreformattedTextRenderer < NodeRenderer

    def process
      { text: @node.text.gsub(' ', Prawn::Text::NBSP) }
    end

  end

  class SimparaRenderer < NodeRenderer

    def process
      res = handle_children({
        'text'     => TextRenderer,
        'emphasis' => EmphasisRenderer,
        'literal'  => LiteralRenderer,
        'ulink'    => UlinkRenderer,
        'xref'     => XrefRenderer,
      })

      @pdf.formatted_text(res.compact)
      @pdf.move_down(10)
    end

  end

  class ParaRenderer < NodeRenderer

    def process
      res = handle_children({
        'text'     => TextRenderer,
        'emphasis' => EmphasisRenderer,
        'literal'  => LiteralRenderer,
        'ulink'    => UlinkRenderer,
        'xref'     => XrefRenderer,
      })

      @pdf.formatted_text(res.compact)
      @pdf.move_down(10)
    end

  end

  class ScreenRenderer < NodeRenderer

    def process
      res = handle_children({
        'text'     => PreformattedTextRenderer,
        'emphasis' => EmphasisRenderer,
        'literal'  => LiteralRenderer,
        'ulink'    => UlinkRenderer,
        'xref'     => XrefRenderer,
      })

      @pdf.indent(20, 20) do
        @pdf.font('Cousine', size: 10) do
          @pdf.formatted_text(res.compact)
        end
        @pdf.move_down(10)
      end
    end

  end

  class ProgramListingRenderer < NodeRenderer

    def process
      res = handle_children({
        'text'     => PreformattedTextRenderer,
        'emphasis' => EmphasisRenderer,
        'literal'  => LiteralRenderer,
        'ulink'    => UlinkRenderer,
        'xref'     => XrefRenderer,
      })

      @pdf.indent(20, 20) do
        @pdf.font('Cousine', size: 10) do
          @pdf.formatted_text(res.compact)
        end
        @pdf.move_down(10)
      end
    end

  end

  class EmphasisRenderer < NodeRenderer

    def process
      { text: @node.text, styles: [ :bold ] }
    end

  end

  class LiteralRenderer < NodeRenderer

    def process
      { text: @node.text, font: 'Cousine', size: 10 }
    end

  end

  class UlinkRenderer < NodeRenderer

    def process
      target = @node[:url]
      text   = @node.children.find { |e| e.text? }.text

      { text: text, link: target }
    end

  end

  class XrefRenderer < NodeRenderer

    def process
      { text: '(missing)' }
    end

  end

end
