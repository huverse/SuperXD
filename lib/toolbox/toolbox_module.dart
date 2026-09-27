import 'package:flutter/material.dart';

import 'package:superxd/toolbox/toolbox_models.dart';

class ToolboxModule {
  const ToolboxModule({
    required this.id,
    required this.name,
    required this.icon,
    required this.builder,
    this.resource,
  });
  final String id;
  final String name;
  final IconData icon;
  final WidgetBuilder builder;
  final ToolboxResource? resource;
}
