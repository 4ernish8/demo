require 'sketchup.rb'

module Detaluvanna
  def self.calculate_dimensions(entity)
    begin
      return nil unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

      local_bbox = Geom::BoundingBox.new
      entity.entities.each do |e|
        next unless e.valid?
        local_bbox.add(e.bounds) if e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge)
      end

      return nil if local_bbox.empty?

      transformation = entity.transformation
      min_point = local_bbox.min.transform(transformation)
      max_point = local_bbox.max.transform(transformation)

      width = ((max_point.x - min_point.x) * 25.4).abs.round
      depth = ((max_point.y - min_point.y) * 25.4).abs.round
      height = ((max_point.z - min_point.z) * 25.4).abs.round

      remaining_sizes = [width, depth, height].sort.reverse

      attribute_dict = entity.attribute_dictionary('ABF')
      if attribute_dict
        label_rotation = attribute_dict['label-rotation']

        if [0, 180].include?(label_rotation)
          width = remaining_sizes[0]
          height = remaining_sizes[1]
        elsif [90, 270].include?(label_rotation)
          width = remaining_sizes[1]
          height = remaining_sizes[0]
        else
          width = remaining_sizes[0]
          height = remaining_sizes[1]
        end
      else
        width = remaining_sizes[0]
        height = remaining_sizes[1]
      end

      [width, height, remaining_sizes[2]]
    rescue => e
      puts "Ошибка при вычислении размеров: #{e.message}"
      puts e.backtrace.join("\n")
      nil
    end
  end

  def self.find_details(entity, details_hash)
    if entity.is_a?(Sketchup::Group) && entity.attribute_dictionaries && entity.attribute_dictionaries["ABF"] && entity.get_attribute("ABF", "is-board") == true
      dimensions = calculate_dimensions(entity)
      if dimensions
        material = entity.material
        material_name = material ? material.name : "Не назначено"
        material_name = material_name.gsub('$', '') # Remove '$'

        key = "#{entity.name}_#{material_name}_#{dimensions.map { |d| d.to_s }.join('_')}"

        if details_hash.key?(key)
          details_hash[key][:count] += 1
        else
          details_hash[key] = {
            name: entity.name,
            dimensions: dimensions,
            material: material_name,
            count: 1,
            paz: ""
          }
        end
        details_hash[key][:paz] = find_paz_settings(entity)
      end
    elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      entity.entities.each { |e| find_details(e, details_hash) }
    end
  end

  def self.find_paz_settings(entity)
    paz_values = []
    if entity.is_a?(Sketchup::Group)
      entity.entities.each do |sub_entity|
        if sub_entity.is_a?(Sketchup::Group) && sub_entity.name.include?("ABF_Intersect")
          if sub_entity.attribute_dictionaries && sub_entity.attribute_dictionaries["ABF"]
            setting_name = sub_entity.get_attribute("ABF", "setting-name")
            paz_values << setting_name if setting_name
          end
        end
      end
    end
    return paz_values.join(", ")
  end

  def self.generate_html_table(details_hash, title, selected_group_name, materials, selected_material, show_material, show_paz)
    sorted_details = details_hash.values.sort_by do |data|
      name = data[:name]
      name.gsub(/(\d+)/) { |match| match.to_i.to_s.rjust(10, '0') } # Numeric sort
    end

    plugin_folder = File.dirname(__FILE__)

    material_filter_html = "<select id='materialFilter' onchange='filterByMaterial(this.value)'>"
    material_filter_html += "<option value=''>Всі матеріали</option>"
    materials.each do |material|
      selected = (material == selected_material) ? "selected" : ""
      material_filter_html += "<option value='#{material}' #{selected}>#{material}</option>"
    end
    material_filter_html += "</select>"

    html = <<-HTML
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <title>#{title}</title>
      <style>
        /* ... (CSS styles - no changes) ... */
        @font-face {
          font-family: 'Balsamiq Sans';
          src: url('https://fonts.gstatic.com/s/balsamiqsans/v7/P5sEzZiAbNrN8SB3lQQX7PqZ-IEIF&7Ptjx8DqsyAA.woff2') format('woff2');
        }
        body {
          font-family: 'Balsamiq Sans', sans-serif;
          font-size: 12px;
          line-height: 1;
          }
          table { border-collapse: collapse; width: 100%; }
          th, td { border: 1px solid black; padding: 8px; }
          th { background-color: #f2f2f2; cursor: pointer; text-align: center; }
          th:hover { background-color: #ddd; }
          .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
          .title { font-size: 18px; font-weight: bold; text-align: center; width: 100%; }
          .buttons { display: flex; gap: 10px; }
          .button-img { width: 24px; height: 24px; cursor: pointer; border: none; background: none; padding: 0;}
          .filter-container { margin-bottom: 10px; }
          .checkbox-container { margin-top: 10px; }
          .hidden { display: none; }
      </style>
    </head>
    <body>
      <div class="header">
        <div class="title">#{selected_group_name ? "Деталювання на модуль \"#{selected_group_name}\"" : title}</div>
        <div class="buttons">
           <img class='button-img' src='file:///#{File.join(plugin_folder, "img/buttons/refresh.png").gsub("\\", "/")}'' onclick='refreshTable()' title='Оновити таблицю'>
           <img class='button-img' src='file:///#{File.join(plugin_folder, "img/buttons/save.png").gsub("\\", "/")}'' onclick='saveToCSV()' title='Зберегти у CSV'>
        </div>
      </div>
      <div class="filter-container">
        #{material_filter_html}
      </div>
      <table id="detailsTable">
        <thead>
          <tr>
            <th onclick="sortTable(0)">№</th>
            <th onclick="sortTable(1)">Назва</th>
            <th onclick="sortTable(2)">Довжина</th>
            <th onclick="sortTable(3)">Ширина</th>
            <th onclick="sortTable(4)">Товщина</th>
            <th onclick="sortTable(5)">Кількість</th>
            <th onclick="sortTable(6)" class="#{show_material ? '' : 'hidden'}">Матеріал</th>
            <th onclick="sortTable(7)" class="#{show_paz ? '' : 'hidden'}">Паз</th>
          </tr>
        </thead>
        <tbody>
    HTML

    sorted_details.each_with_index do |data, index|
      html += <<-HTML
          <tr>
            <td style="text-align: center;">#{index + 1}</td>
            <td>#{data[:name]}</td>
            <td style="text-align: center;">#{data[:dimensions][0]}</td>
            <td style="text-align: center;">#{data[:dimensions][1]}</td>
            <td style="text-align: center;">#{data[:dimensions][2]}</td>
            <td style="text-align: center;">#{data[:count]}</td>
            <td class="#{show_material ? '' : 'hidden'}">#{data[:material]}</td>
            <td style="text-align: center;" class="#{show_paz ? '' : 'hidden'}">#{data[:paz]}</td>
          </tr>
      HTML
    end

    html += <<-HTML
        </tbody>
      </table>
      <div class="checkbox-container">
        <label><input type="checkbox" id="showMaterial" onchange="toggleColumn('material', this.checked)" #{show_material ? 'checked' : ''}> Матеріал</label>
        <label><input type="checkbox" id="showPaz" onchange="toggleColumn('paz', this.checked)" #{show_paz ? 'checked' : ''}> Паз</label>
      </div>

      <script>
        function sortTable(n) {
          // ... (код sortTable - без змін) ...
        }
        function refreshTable() {
          sketchup.refreshTable();
        }
        function saveToCSV() {
          sketchup.saveToCSV();
        }
        function filterByMaterial(selectedMaterial) {
            sketchup.filterByMaterial(selectedMaterial);
        }

        function toggleColumn(column, show) {
            sketchup.toggleColumn(column, show);
        }

      </script>
    </body>
    </html>
    HTML

    html
  end

  def self.run(selection = nil)
    model = Sketchup.active_model
    selection ||= model.selection

    # Функція для оновлення даних
    update_data = Proc.new do
      details_hash = {}
      title = "Деталювання"
      selected_group_name = nil

      current_selection = Sketchup.active_model.selection
      if current_selection.empty?
        model.entities.each { |entity| find_details(entity, details_hash) }
      else
        if current_selection.length == 1 && (current_selection[0].is_a?(Sketchup::Group) || current_selection[0].is_a?(Sketchup::ComponentInstance))
          selected_group_name = current_selection[0].name
        end
        current_selection.each { |entity| find_details(entity, details_hash) }
      end

      materials = details_hash.values.map { |data| data[:material] }.uniq.sort
      [details_hash, title, selected_group_name, materials]
    end

    # Початкові значення
    details_hash, title, selected_group_name, materials = update_data.call()
    selected_material = ''  # Початково вибраний матеріал (всі)
    show_material = true
    show_paz = true
    filtered_details = details_hash # Спочатку всі деталі

    return if details_hash.empty?

    dialog = UI::HtmlDialog.new(
      dialog_title: title,
      scrollable: true,
      width: 800,
      height: 650,
      left: 100,
      top: 100,
      style: UI::HtmlDialog::STYLE_DIALOG
    )

    dialog.add_action_callback("refreshTable") do |_action_context|
      # 1. Оновлюємо дані (отримуємо новий details_hash)
      new_details_hash, new_title, new_selected_group_name, new_materials = update_data.call()

      # 2. Скидаємо фільтр *перед* перемальовуванням.
      selected_material = ''

      # 3. Фільтруємо дані (в даному випадку - показуємо все, бо фільтр скинуто)
      filtered_details = new_details_hash

      # 4. Перемальовуємо таблицю з новими даними і скинутим фільтром.
      html_content = generate_html_table(filtered_details, new_title, new_selected_group_name, new_materials, selected_material, show_material, show_paz)
      dialog.set_html(html_content)
    end
    dialog.add_action_callback("saveToCSV") do |_action_context|
      filepath = UI.savepanel("Зберегти деталювання", "", "деталювання.csv")
      return unless filepath
      filepath += ".csv" unless filepath.downcase.end_with?(".csv")

      File.open(filepath, "w:UTF-8") do |file|
        file.write("\uFEFF") # BOM

        header = "№;Назва;Довжина;Ширина;Товщина;Кількість"
        header += ";Матеріал" if show_material
        header += ";Паз" if show_paz
        file.puts header

        filtered_details.sort_by { |k, v| v[:name] }.each_with_index do |(key, data), index|
          row = "#{index + 1};#{data[:name]};#{data[:dimensions][0]};#{data[:dimensions][1]};#{data[:dimensions][2]};#{data[:count]}"
          row += ";#{data[:material]}" if show_material
          row += ";#{data[:paz]}" if show_paz
          file.puts row
        end
      end
      UI.messagebox("Деталювання збережено:\n#{filepath}")
    end

    dialog.add_action_callback("filterByMaterial") do |_action_context, material|
      selected_material = material  # Оновлюємо вибраний матеріал
      filtered_details = {}

      if material.empty?
        filtered_details = details_hash  # Якщо "Всі матеріали", показуємо всі
      else
        details_hash.each do |key, data|
          filtered_details[key] = data if data[:material] == material  # Фільтруємо
        end
      end

      html_content = generate_html_table(filtered_details, title, selected_group_name, materials, selected_material, show_material, show_paz)
      dialog.set_html(html_content)
    end

    dialog.add_action_callback("toggleColumn") do |_action_context, column, show|
      if column == "material"
        show_material = show
      elsif column == "paz"
        show_paz = show
      end
      # Не треба окремо фільтрувати. Просто перемальовуємо з новими show_material/show_paz
      html_content = generate_html_table(filtered_details, title, selected_group_name, materials, selected_material, show_material, show_paz)
      dialog.set_html(html_content)
    end


    # Початкове створення таблиці (з усіма даними, бо selected_material = '')
    html_content = generate_html_table(filtered_details, title, selected_group_name, materials, selected_material, show_material, show_paz)
    dialog.set_html(html_content)
    dialog.show
  end

end