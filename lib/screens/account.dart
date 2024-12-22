import 'package:flutter/material.dart';
import 'package:second_times_the_charm/models/global-resource/settings_info.dart';
import 'package:second_times_the_charm/widgets/app-bar-widgets/default_app_bar.dart';

import '../models/global-resource/app_colors.dart';
import 'package:provider/provider.dart';


class Account extends StatelessWidget {

  const Account({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
        create: (_) => AccountLogic(),
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: DefaultAppBar(popUpText: ''),

        body: Column(
          children: [
            Expanded(
              child: Consumer<AccountLogic>(
                builder: (context, accountLogic, child){
                  return ListView.builder(
                    itemCount: settingsInfo.length,
                    itemBuilder: (context, index) {
                      return GestureDetector(
                        onTap: () {
                          final func = settingsInfo[index]['func'];
                          if (func != null && func is Function) {
                            func(context);
                          } else {
                            assert(func != null && func is Function);
                          }
                        },
                        child: Container(
                          padding: EdgeInsets.all(18.0),
                          decoration: BoxDecoration( border: Border(
                              bottom: BorderSide(color: AppColors.divider))
                          ),
                          child: Text(
                            settingsInfo[index]['name'],
                            style: TextStyle(fontSize: 25.0, color: AppColors.textPrimary),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AccountLogic with ChangeNotifier {
  void renderOptions(){
     notifyListeners();
  }

}
