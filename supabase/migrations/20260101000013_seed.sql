-- 013 Reference data
insert into public.service_categories (slug, name, sort_order) values
  ('plumbing',            'Plumbing',                       10),
  ('electrical',          'Electrical',                     20),
  ('air-conditioning',    'Air-conditioning',               30),
  ('painting',            'Painting',                       40),
  ('carpentry',           'Carpentry & furniture',          50),
  ('tiling-flooring',     'Tiling & flooring',              60),
  ('waterproofing-roof',  'Waterproofing & roofing',        70),
  ('renovation',          'Renovation & general repair',    80)
on conflict (slug) do nothing;
