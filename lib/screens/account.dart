import 'package:flutter/material.dart';
import 'package:second_times_the_charm/widgets/default_app_bar.dart';

import '../models/app_colors.dart';


class Account extends StatefulWidget {
  final String title;

  const Account({
    required this.title,
    super.key
  });

  @override
  State<Account> createState() => _AccountState();
}


class _AccountState extends State<Account>{







  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: DefaultAppBar(subtitle: 'Account', popUpText: ''),
    );
  }

}