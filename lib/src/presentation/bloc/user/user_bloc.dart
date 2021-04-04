import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_bloc_base/firebase_bloc_base.dart';
import 'package:firebase_bloc_base/src/data/repository/user_repository.dart';
import 'package:firebase_bloc_base/src/domain/entity/response_entity.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:rxdart/rxdart.dart';

import 'user_state.dart';

class BaseUserBloc<UserType extends FirebaseProfile> extends Cubit<UserState> {
  final emailVerificationDaysLimit = Duration(days: 7);

  final UserRepository<UserType> _userRepository;

  final _user = BehaviorSubject<User>();
  final _userAccount = BehaviorSubject<UserType>();

  StreamSubscription<UserType> _detailsSubscription;
  StreamSubscription<User> _userSubscription;
  Stream<User> get userChanges => _user.shareValue();
  Stream<UserType> get userStream => _userAccount.shareValue();

  bool signedUp;

  FirebaseProfile currentUser;

  BaseUserBloc(this._userRepository) : super(UserLoadingState()) {
    autoSignIn().catchError((e, s) {
      print(e);
      print(s);
    });
    _userSubscription = _userRepository.userChanges.listen((User event) {
      _user.add(event);
      if (event == null && state is SignedInState) {
        emit(SignedOutState());
      }
    });
  }

  @override
  void onChange(change) {
    handleTransition(change.nextState);
    super.onChange(change);
  }

  void handleTransition(UserState state) {
    if (state is SignedOutState) {
      currentUser = null;
      signedUp = false;
      _detailsSubscription?.cancel();
    }
    if (_userAccount.value != currentUser) {
      _userAccount.add(currentUser);
    }
  }

  UserType syncUserDetails(UserType account, User user) {
    account = account.copyWith(userDetails: user);
    return account;
  }

  Future<void> autoSignIn() async {
    signedUp = false;
    final Either<Failure, Stream<UserType>> result =
        await _userRepository.autoSignIn();
    Completer<Either<Failure, UserType>> completer = _userCompleter(result);
    final futureResult = await completer.future;
    futureResult.fold((l) => emit(SignedOutState()), (UserType r) {});
  }

  Future<Either<Failure, UserType>> signIn(
      String email, String password) async {
    signedUp = false;
    final result = await _userRepository.signIn(email, password);
    Completer<Either<Failure, UserType>> completer = _userCompleter(result);
    return completer.future;
  }

  Future<Either<Failure, UserType>> signUp(
      String firstName, String lastName, String email, String password) async {
    signedUp = true;
    final result =
        await _userRepository.signUp(firstName, lastName, email, password);
    Completer<Either<Failure, UserType>> completer = _userCompleter(result);
    return completer.future;
  }

  Future<Either<Failure, UserType>> updateUser(UserType newDetails,
      {String phoneNumber,
      String email,
      Future<String> Function() getCode}) async {
    final result = await _userRepository.updateUserAccount(
        newDetails, phoneNumber, email, getCode);
    return result;
  }

  Future<Either<Failure, UserCredential>> addPhoneNumber(
      String phoneNumber, Future<String> Function() getCode) async {
    final result = await _userRepository.addPhoneNumber(phoneNumber, getCode);
    return result;
  }

  Future<Either<Failure, void>> resetPassword(String email) async {
    final result = await _userRepository.resetPassword(email);
    return result;
  }

  Future<Failure> signOut() async {
    final result = await _userRepository.signOut();
    if (result == null) {
      currentUser = null;
      emit(SignedOutState());
    }
    return result;
  }

  Future<Either<Failure, void>> sendEmailVerification() async {
    final operation = currentUser?.userDetails?.sendEmailVerification();
    if (operation != null) {
      try {
        final result = await operation;
        return Right(result);
      } catch (e, s) {
        return Left(Failure('Failed to send the email.'));
      }
    }
    return Left(Failure('Failed to send the email.'));
  }

  Completer<Either<Failure, UserType>> _userCompleter(
      Either<Failure, Stream<UserType>> result) {
    Completer<Either<Failure, UserType>> completer = Completer();
    result.fold((l) {
      if (!completer.isCompleted) {
        completer.complete(Left(l));
      }
    }, (r) {
      _detailsSubscription?.cancel();
      _detailsSubscription = null;
      final newStream = CombineLatestStream.combine2<UserType, User, UserType>(
          r, userChanges, (userAccount, user) {
        if (userAccount != null && user != null) {
          return syncUserDetails(userAccount, user);
        }
        return null;
      });
      _detailsSubscription = newStream.listen((event) {
        if (!completer.isCompleted) {
          completer.complete(Right(event));
        }
        _handleUser(event);
      }, onError: (e, s) {
        if (!completer.isCompleted) {
          completer.completeError(e, s);
        }
        signOut();
        emit(SignedOutState());
      });
    });
    return completer;
  }

  Future<void> _handleUser(UserType event) async {
    currentUser = event;
    if (currentUser == null) {
      emit(SignedOutState());
    } else {
      final verificationLimit = currentUser.userDetails.metadata.creationTime
          .add(emailVerificationDaysLimit);
      final now = DateTime.now();
      if (currentUser.email != 'testing@test.com' &&
          !currentUser.emailVerified &&
          verificationLimit.isBefore(now)) {
        emit(SignedInWithNoVerifiedEmailState(currentUser));
      } else {
        emitSignedUser(currentUser);
      }
    }
  }

  void emitSignedUser(FirebaseProfile currentUser) {}

  void completeSignUp() {
    signedUp = false;
    _handleUser(currentUser);
  }

  @override
  Future<void> close() {
    _detailsSubscription?.cancel();
    _userSubscription?.cancel();
    _user.close();
    _userAccount.close();
    return super.close();
  }
}